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
    private var activeSources: [String: WallpaperSource] = [:]
    private var lastSources: [String: WallpaperSource] = [:]
    private var staticWallpapers: [String: URL] = [:]
    private var pausedScreens: Set<String> = []
    private var wePropertyJS: [String: String] = [:]
    private var dynamicMenu: NSMenu!
    private var staticMenu: NSMenu!
    private var mouseMonitor: Any?

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
        menu.addItem(NSMenuItem(title: L.setVideoAll, action: #selector(selectVideoForAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.setStaticAll, action: #selector(setStaticForAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.importWE, action: #selector(importWEForAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L.pauseResumeAll, action: #selector(togglePauseAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.stopAll, action: #selector(stopAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.resumeAll, action: #selector(resumeAll), keyEquivalent: ""))
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

            let videoItem = NSMenuItem(title: L.selectVideo, action: #selector(selectVideoForScreen(_:)), keyEquivalent: "")
            videoItem.tag = index
            sub.addItem(videoItem)

            let weItem = NSMenuItem(title: L.importWEFolder, action: #selector(importWEForScreen(_:)), keyEquivalent: "")
            weItem.tag = index
            sub.addItem(weItem)

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

    // MARK: - Actions: Video

    @objc private func selectVideoForScreen(_ sender: NSMenuItem) {
        guard let url = pickFile(types: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi], title: L.selectVideoTitle) else { return }
        showWallpaper(screen: NSScreen.screens[sender.tag], source: WallpaperSource(type: .video, path: url.path))
    }

    @objc private func selectVideoForAll() {
        guard let url = pickFile(types: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi], title: L.selectVideoTitle) else { return }
        let source = WallpaperSource(type: .video, path: url.path)
        NSScreen.screens.forEach { showWallpaper(screen: $0, source: source) }
    }

    // MARK: - Actions: WE Import

    @objc private func importWEForScreen(_ sender: NSMenuItem) {
        guard let result = pickWEFolder() else { return }
        let name = NSScreen.screens[sender.tag].localizedName
        if let js = result.propertyJS { wePropertyJS[name] = js }
        showWallpaper(screen: NSScreen.screens[sender.tag], source: result.source)
    }

    @objc private func importWEForAll() {
        guard let result = pickWEFolder() else { return }
        for screen in NSScreen.screens {
            if let js = result.propertyJS { wePropertyJS[screen.localizedName] = js }
            showWallpaper(screen: screen, source: result.source)
        }
    }

    private func pickWEFolder() -> WEParseResult? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L.selectWETitle
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let result = parseWEProject(at: url) else {
            let alert = NSAlert()
            alert.messageText = L.unsupportedWE
            alert.informativeText = "Only 'video' and 'web' types are supported."
            alert.runModal()
            return nil
        }
        return result
    }

    // MARK: - Actions: Pause / Stop / Restore

    @objc private func togglePauseScreen(_ sender: NSMenuItem) {
        let name = NSScreen.screens[sender.tag].localizedName
        setPaused(!pausedScreens.contains(name), for: name)
    }

    @objc private func togglePauseAll() {
        let shouldPause = !activeSources.keys.allSatisfy { pausedScreens.contains($0) }
        for name in activeSources.keys { setPaused(shouldPause, for: name) }
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
