import AppKit
import AVFoundation
import UniformTypeIdentifiers
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var wallpaperWindows: [String: NSWindow] = [:]
    private var players: [String: AVPlayer] = [:]
    private var webViews: [String: WKWebView] = [:]
    #if ENABLE_SCENE
    private var sceneEngines: [String: SceneEngine] = [:]
    #endif
    private var activeSources: [String: WallpaperSource] = [:]
    private var lastSources: [String: WallpaperSource] = [:]
    private var staticWallpapers: [String: URL] = [:]
    private var pausedScreens: Set<String> = []
    private var wePropertyJS: [String: String] = [:]
    private var dynamicMenu: NSMenu!
    private var staticMenu: NSMenu!
    private var mouseMonitor: Any?
    private var audioMuted = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureBlackImage()
        L.lang = loadLang()
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])
        }
        setupMenuBar()
        startMouseTracking()
        restoreConfig()
        applyStaticToInactiveScreens()
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforceBlackOnActiveScreens()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        persistConfig()
        applyStaticToAllScreens()
    }

    // MARK: - Mouse Tracking

    private func startMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.injectMouseEvent(event) }
        }
    }

    private func injectMouseEvent(_ event: NSEvent) {
        let loc = NSEvent.mouseLocation
        let jsEvent: String
        switch event.type {
        case .leftMouseDown: jsEvent = "mousedown"
        case .leftMouseUp: jsEvent = "mouseup"
        default: jsEvent = "mousemove"
        }
        for (name, webView) in webViews {
            guard let window = wallpaperWindows[name] else { continue }
            let pt = window.convertPoint(fromScreen: loc)
            let y = window.frame.height - pt.y
            guard pt.x >= 0, pt.x <= window.frame.width, pt.y >= 0, pt.y <= window.frame.height else { continue }
            webView.evaluateJavaScript(
                "(function(){var el=document.elementFromPoint(\(pt.x),\(y))||document;el.dispatchEvent(new MouseEvent('\(jsEvent)',{clientX:\(pt.x),clientY:\(y),bubbles:true}))})();",
                completionHandler: nil
            )
        }
        #if ENABLE_SCENE
        // Pass mouse to scene engines
        for (name, engine) in sceneEngines {
            guard let window = wallpaperWindows[name] else { continue }
            let pt = window.convertPoint(fromScreen: loc)
            guard pt.x >= 0, pt.x <= window.frame.width, pt.y >= 0, pt.y <= window.frame.height else { continue }
            engine.updateMouse(Float(pt.x / window.frame.width), Float(1 - pt.y / window.frame.height))
        }
        #endif
    }

    // MARK: - Config

    private func persistConfig() {
        var config = AppConfig(screens: [:])
        let allNames = Set(activeSources.keys)
            .union(lastSources.keys)
            .union(staticWallpapers.keys)
            .union(NSScreen.screens.map { $0.localizedName })
        for name in allNames {
            config.screens[name] = ScreenConfig(
                wallpaperSource: activeSources[name] ?? lastSources[name],
                paused: pausedScreens.contains(name),
                staticWallpaperPath: staticWallpapers[name]?.path
            )
        }
        saveConfig(config)
    }

    private func restoreConfig() {
        let config = loadConfig()
        for (name, sc) in config.screens {
            if let p = sc.staticWallpaperPath, FileManager.default.fileExists(atPath: p) {
                staticWallpapers[name] = URL(fileURLWithPath: p)
            }
            if let source = sc.wallpaperSource {
                lastSources[name] = source
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else { continue }
                showWallpaper(screen: screen, source: source)
                if sc.paused {
                    pausedScreens.insert(name)
                    players[name]?.pause()
                }
            }
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = "▶"
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let dynItem = NSMenuItem(title: L.dynamicScreens, action: nil, keyEquivalent: "")
        dynamicMenu = NSMenu()
        dynItem.submenu = dynamicMenu
        menu.addItem(dynItem)

        let staItem = NSMenuItem(title: L.staticScreens, action: nil, keyEquivalent: "")
        staticMenu = NSMenu()
        staItem.submenu = staticMenu
        menu.addItem(staItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L.setWallpaperAll, action: #selector(selectWallpaperForAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.setStaticAll, action: #selector(setStaticForAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let allPaused = !activeSources.isEmpty && activeSources.keys.allSatisfy { pausedScreens.contains($0) }
        menu.addItem(NSMenuItem(title: allPaused ? L.resumeAll : L.pauseAll, action: #selector(togglePauseAll), keyEquivalent: ""))
        let hasActive = !activeSources.isEmpty
        let hasRestorable = lastSources.keys.contains(where: { activeSources[$0] == nil })
        if hasActive {
            menu.addItem(NSMenuItem(title: L.stopAll, action: #selector(stopAll), keyEquivalent: ""))
        } else if hasRestorable {
            menu.addItem(NSMenuItem(title: L.restoreAll, action: #selector(resumeAll), keyEquivalent: ""))
        }
        let muteItem = NSMenuItem(title: audioMuted ? L.unmuteAudio : L.muteAudio, action: #selector(toggleMute), keyEquivalent: "")
        menu.addItem(muteItem)
        menu.addItem(NSMenuItem.separator())

        let langItem = NSMenuItem(title: L.language, action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let zhItem = NSMenuItem(title: "中文", action: #selector(setLangZh), keyEquivalent: "")
        let enItem = NSMenuItem(title: "English", action: #selector(setLangEn), keyEquivalent: "")
        zhItem.state = L.lang == .zh ? .on : .off
        enItem.state = L.lang == .en ? .on : .off
        langMenu.addItem(zhItem)
        langMenu.addItem(enItem)
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L.quit, action: #selector(quit), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshDynamicMenu() {
        dynamicMenu.removeAllItems()
        for (index, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let screenItem = NSMenuItem(title: "\(name) (\(index + 1))", action: nil, keyEquivalent: "")
            let sub = NSMenu()

            if let source = activeSources[name] {
                let status = pausedScreens.contains(name) ? "⏸" : "▶"
                let info = NSMenuItem(title: "\(status) \(source.displayName)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                sub.addItem(info)
                sub.addItem(NSMenuItem.separator())
            }

            let selectItem = NSMenuItem(title: L.selectWallpaper, action: #selector(selectWallpaperForScreen(_:)), keyEquivalent: "")
            selectItem.tag = index
            sub.addItem(selectItem)

            if activeSources[name] != nil {
                sub.addItem(NSMenuItem.separator())
                let pauseItem = NSMenuItem(title: pausedScreens.contains(name) ? L.resume : L.pause,
                                           action: #selector(togglePauseScreen(_:)), keyEquivalent: "")
                pauseItem.tag = index
                sub.addItem(pauseItem)
                let stopItem = NSMenuItem(title: L.stop, action: #selector(stopScreen(_:)), keyEquivalent: "")
                stopItem.tag = index
                sub.addItem(stopItem)
            } else if let last = lastSources[name] {
                sub.addItem(NSMenuItem.separator())
                let item = NSMenuItem(title: "\(L.restore) (\(last.displayName))",
                                      action: #selector(restoreScreen(_:)), keyEquivalent: "")
                item.tag = index
                sub.addItem(item)
            }

            screenItem.submenu = sub
            dynamicMenu.addItem(screenItem)
        }
    }

    private func refreshStaticMenu() {
        staticMenu.removeAllItems()
        for (index, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let screenItem = NSMenuItem(title: "\(name) (\(index + 1))", action: nil, keyEquivalent: "")
            let sub = NSMenu()

            let info = NSMenuItem(title: "\(L.current): \(staticWallpapers[name]?.lastPathComponent ?? L.solidBlack)",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(NSMenuItem.separator())

            let blackItem = NSMenuItem(title: L.solidBlack, action: #selector(setScreenStaticBlack(_:)), keyEquivalent: "")
            blackItem.tag = index
            sub.addItem(blackItem)
            let imageItem = NSMenuItem(title: L.chooseImage, action: #selector(setScreenStaticImage(_:)), keyEquivalent: "")
            imageItem.tag = index
            sub.addItem(imageItem)

            screenItem.submenu = sub
            staticMenu.addItem(screenItem)
        }
    }

    // MARK: - Language

    @objc private func setLangZh() { L.lang = .zh; saveLang(.zh); rebuildMenu() }
    @objc private func setLangEn() { L.lang = .en; saveLang(.en); rebuildMenu() }

    @objc private func toggleMute() {
        audioMuted.toggle()
        #if ENABLE_SCENE
        for engine in sceneEngines.values {
            engine.audioPlayer?.volume = audioMuted ? 0 : 0.5
        }
        #endif
        rebuildMenu()
    }

    // MARK: - Actions: Select Wallpaper (unified)

    @objc private func selectWallpaperForScreen(_ sender: NSMenuItem) {
        guard let source = pickWallpaper() else { return }
        let name = NSScreen.screens[sender.tag].localizedName
        if let js = source.1 { wePropertyJS[name] = js }
        showWallpaper(screen: NSScreen.screens[sender.tag], source: source.0)
    }

    @objc private func selectWallpaperForAll() {
        guard let source = pickWallpaper() else { return }
        for screen in NSScreen.screens {
            if let js = source.1 { wePropertyJS[screen.localizedName] = js }
            showWallpaper(screen: screen, source: source.0)
        }
    }

    /// Unified picker: files (video/image) + folders (WE wallpaper)
    private func pickWallpaper() -> (WallpaperSource, String?)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L.selectWallpaperTitle
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            // Folder → WE wallpaper
            guard let result = parseWEProject(at: url) else {
                let alert = NSAlert()
                alert.messageText = L.unsupportedWE
                alert.informativeText = "Only 'video', 'web', and 'scene' types are supported."
                alert.runModal()
                return nil
            }
            return (result.source, result.propertyJS)
        } else {
            // File → detect type
            let ext = url.pathExtension.lowercased()
            let videoExts = Set(["mp4", "mov", "avi", "mkv", "m4v", "webm", "wmv", "flv", "mpg", "mpeg"])
            let imageExts = Set(["jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "bmp", "webp", "gif"])

            if videoExts.contains(ext) {
                return (WallpaperSource(type: .video, path: url.path), nil)
            } else if imageExts.contains(ext) {
                return (WallpaperSource(type: .image, path: url.path, title: url.lastPathComponent), nil)
            } else {
                let alert = NSAlert()
                alert.messageText = L.unsupportedFile
                alert.runModal()
                return nil
            }
        }
    }

    // MARK: - Actions: Pause / Stop / Restore

    @objc private func togglePauseScreen(_ sender: NSMenuItem) {
        let name = NSScreen.screens[sender.tag].localizedName
        setPaused(!pausedScreens.contains(name), for: name)
    }

    @objc private func togglePauseAll() {
        let shouldPause = !activeSources.keys.allSatisfy { pausedScreens.contains($0) }
        for name in activeSources.keys { setPaused(shouldPause, for: name) }
        rebuildMenu()
    }

    private func setPaused(_ paused: Bool, for name: String) {
        if paused {
            pausedScreens.insert(name)
            players[name]?.pause()
            webViews[name]?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(v=>v.pause())", completionHandler: nil)
        } else {
            pausedScreens.remove(name)
            players[name]?.play()
            webViews[name]?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(v=>v.play())", completionHandler: nil)
        }
    }

    @objc private func stopScreen(_ sender: NSMenuItem) {
        let screen = NSScreen.screens[sender.tag]
        let name = screen.localizedName
        if let s = activeSources[name] { lastSources[name] = s }
        teardownScreen(name: name)
        activeSources.removeValue(forKey: name)
        pausedScreens.remove(name)
        applyStaticWallpaper(for: screen)
    }

    @objc private func stopAll() {
        for (n, s) in activeSources { lastSources[n] = s }
        for n in activeSources.keys { teardownScreen(name: n) }
        activeSources.removeAll()
        pausedScreens.removeAll()
        applyStaticToAllScreens()
        rebuildMenu()
    }

    @objc private func restoreScreen(_ sender: NSMenuItem) {
        let screen = NSScreen.screens[sender.tag]
        guard let source = lastSources[screen.localizedName] else { return }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        showWallpaper(screen: screen, source: source)
    }

    @objc private func resumeAll() {
        for screen in NSScreen.screens {
            let name = screen.localizedName
            if activeSources[name] != nil { continue }
            guard let source = lastSources[name], FileManager.default.fileExists(atPath: source.path) else { continue }
            showWallpaper(screen: screen, source: source)
        }
        rebuildMenu()
    }

    // MARK: - Actions: Static

    @objc private func setScreenStaticBlack(_ sender: NSMenuItem) {
        let name = NSScreen.screens[sender.tag].localizedName
        staticWallpapers.removeValue(forKey: name)
        if activeSources[name] == nil { applyStaticWallpaper(for: NSScreen.screens[sender.tag]) }
    }

    @objc private func setScreenStaticImage(_ sender: NSMenuItem) {
        guard let url = pickFile(types: [.image, .png, .jpeg, .tiff, .heic, .bmp, .webP], title: L.selectImageTitle) else { return }
        let name = NSScreen.screens[sender.tag].localizedName
        staticWallpapers[name] = url
        if activeSources[name] == nil { applyStaticWallpaper(for: NSScreen.screens[sender.tag]) }
    }

    @objc private func setStaticForAll() {
        guard let url = pickFile(types: [.image, .png, .jpeg, .tiff, .heic, .bmp, .webP], title: L.selectImageTitle) else { return }
        for screen in NSScreen.screens {
            staticWallpapers[screen.localizedName] = url
            if activeSources[screen.localizedName] == nil { applyStaticWallpaper(for: screen) }
        }
    }

    // MARK: - Quit

    @objc private func quit() {
        persistConfig()
        for n in activeSources.keys { teardownScreen(name: n) }
        activeSources.removeAll()
        applyStaticToAllScreens()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func pickFile(types: [UTType], title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = title
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func applyStaticWallpaper(for screen: NSScreen) {
        try? NSWorkspace.shared.setDesktopImageURL(staticWallpapers[screen.localizedName] ?? blackImageURL, for: screen, options: [:])
    }

    private func applyStaticToAllScreens() {
        NSScreen.screens.forEach { applyStaticWallpaper(for: $0) }
    }

    private func applyStaticToInactiveScreens() {
        for screen in NSScreen.screens where activeSources[screen.localizedName] == nil {
            applyStaticWallpaper(for: screen)
        }
    }

    private func enforceBlackOnActiveScreens() {
        for screen in NSScreen.screens where activeSources[screen.localizedName] != nil {
            try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])
        }
    }

    private func teardownScreen(name: String) {
        players[name]?.pause()
        players.removeValue(forKey: name)
        webViews.removeValue(forKey: name)
        #if ENABLE_SCENE
        sceneEngines.removeValue(forKey: name)
        #endif
        wallpaperWindows[name]?.orderOut(nil)
        wallpaperWindows.removeValue(forKey: name)
    }

    private func showWallpaper(screen: NSScreen, source: WallpaperSource) {
        let name = screen.localizedName
        teardownScreen(name: name)
        try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])

        let window = createWallpaperWindow(screen: screen)

        switch source.type {
        case .video:
            players[name] = setupVideoContent(window: window, screen: screen, path: source.path)
        case .web:
            webViews[name] = setupWebContent(
                window: window, screen: screen,
                fileURL: URL(fileURLWithPath: source.path),
                propertyJS: wePropertyJS[name]
            )
        case .scene:
            #if ENABLE_SCENE
            sceneEngines[name] = setupSceneContent(
                window: window, screen: screen,
                sceneDir: URL(fileURLWithPath: source.path)
            )
            #else
            // Stable build: scene wallpapers are not supported
            return
            #endif
        case .image:
            setupImageContent(window: window, screen: screen, path: source.path)
        }

        window.orderFront(nil)
        wallpaperWindows[name] = window
        activeSources[name] = source
        lastSources[name] = source
        pausedScreens.remove(name)
    }
}

// MARK: - Menu Delegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshDynamicMenu()
        refreshStaticMenu()
    }
}
