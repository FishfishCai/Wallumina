import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = WallpaperController()
    private var statusItem: NSStatusItem!
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
        controller.restore()
        rebuildMenu() // restore() populates activeSources — rebuild so Stop All appears
        controller.applyStaticToInactiveScreens()
        // macOS resets the desktop image a few times after launch; reinforce our black placeholder
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.controller.enforceBlackOnActiveScreens()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        controller.persist()
        controller.applyStaticToAllScreens()
    }

    // MARK: - Mouse tracking

    private func startMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.controller.injectMouseEvent(event) }
        }
    }

    // MARK: - Menu bar

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

        let active = controller.activeSources
        let allPaused = !active.isEmpty && active.keys.allSatisfy { controller.isPaused($0) }
        menu.addItem(NSMenuItem(title: allPaused ? L.resumeAll : L.pauseAll,
                                action: #selector(togglePauseAll), keyEquivalent: ""))

        let hasActive = !active.isEmpty
        let hasRestorable = controller.lastSources.keys.contains(where: { active[$0] == nil })
        if hasActive {
            menu.addItem(NSMenuItem(title: L.stopAll, action: #selector(stopAll), keyEquivalent: ""))
        } else if hasRestorable {
            menu.addItem(NSMenuItem(title: L.restoreAll, action: #selector(resumeAll), keyEquivalent: ""))
        }
        let muteItem = NSMenuItem(title: controller.isAudioMuted ? L.unmuteAudio : L.muteAudio,
                                  action: #selector(toggleMute), keyEquivalent: "")
        menu.addItem(muteItem)
        menu.addItem(NSMenuItem.separator())

        let langItem = NSMenuItem(title: L.language, action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let zhItem = NSMenuItem(title: "中文", action: #selector(setLangZh), keyEquivalent: "")
        let enItem = NSMenuItem(title: "English", action: #selector(setLangEn), keyEquivalent: "")
        zhItem.state = L.lang == .zh ? .on : .off
        enItem.state = L.lang == .en ? .on : .off
        langMenu.addItem(zhItem); langMenu.addItem(enItem)
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

            if let source = controller.activeSources[name] {
                let status = controller.isPaused(name) ? "⏸" : "▶"
                let info = NSMenuItem(title: "\(status) \(source.displayName)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                sub.addItem(info)
                sub.addItem(NSMenuItem.separator())
            }

            let selectItem = NSMenuItem(title: L.selectWallpaper,
                                         action: #selector(selectWallpaperForScreen(_:)),
                                         keyEquivalent: "")
            selectItem.tag = index
            sub.addItem(selectItem)

            if controller.activeSources[name] != nil {
                sub.addItem(NSMenuItem.separator())
                let pauseItem = NSMenuItem(
                    title: controller.isPaused(name) ? L.resume : L.pause,
                    action: #selector(togglePauseScreen(_:)),
                    keyEquivalent: ""
                )
                pauseItem.tag = index
                sub.addItem(pauseItem)
                let stopItem = NSMenuItem(title: L.stop, action: #selector(stopScreen(_:)), keyEquivalent: "")
                stopItem.tag = index
                sub.addItem(stopItem)
            } else if let last = controller.lastSources[name] {
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

            let info = NSMenuItem(
                title: "\(L.current): \(controller.staticWallpapers[name]?.lastPathComponent ?? L.solidBlack)",
                action: nil, keyEquivalent: ""
            )
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(NSMenuItem.separator())

            let blackItem = NSMenuItem(title: L.solidBlack,
                                        action: #selector(setScreenStaticBlack(_:)),
                                        keyEquivalent: "")
            blackItem.tag = index
            sub.addItem(blackItem)
            let imageItem = NSMenuItem(title: L.chooseImage,
                                        action: #selector(setScreenStaticImage(_:)),
                                        keyEquivalent: "")
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
        controller.setAudioMuted(!controller.isAudioMuted)
        rebuildMenu()
    }

    // MARK: - Actions: select wallpaper

    @objc private func selectWallpaperForScreen(_ sender: NSMenuItem) {
        guard let picked = pickWallpaper() else { return }
        controller.show(on: NSScreen.screens[sender.tag], source: picked.source, propertyJS: picked.propertyJS)
        rebuildMenu()
    }

    @objc private func selectWallpaperForAll() {
        guard let picked = pickWallpaper() else { return }
        for screen in NSScreen.screens {
            controller.show(on: screen, source: picked.source, propertyJS: picked.propertyJS)
        }
        rebuildMenu()
    }

    /// Unified picker: files (video/image) + folders (WE wallpaper).
    private func pickWallpaper() -> (source: WallpaperSource, propertyJS: String?)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L.selectWallpaperTitle
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            guard let result = parseWEProject(at: url) else {
                let alert = NSAlert()
                alert.messageText = L.unsupportedWE
                alert.informativeText = "Only 'video', 'web', and 'scene' types are supported."
                alert.runModal()
                return nil
            }
            return (result.source, result.propertyJS)
        }

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

    // MARK: - Actions: pause / stop / restore

    @objc private func togglePauseScreen(_ sender: NSMenuItem) {
        let name = NSScreen.screens[sender.tag].localizedName
        controller.togglePause(for: name)
        rebuildMenu()
    }

    @objc private func togglePauseAll() {
        controller.toggleAllPaused()
        rebuildMenu()
    }

    @objc private func stopScreen(_ sender: NSMenuItem) {
        controller.stop(screen: NSScreen.screens[sender.tag])
        rebuildMenu()
    }

    @objc private func stopAll() {
        controller.stopAllActive()
        rebuildMenu()
    }

    @objc private func restoreScreen(_ sender: NSMenuItem) {
        controller.restoreLast(on: NSScreen.screens[sender.tag])
        rebuildMenu()
    }

    @objc private func resumeAll() {
        controller.resumeAllLast()
        rebuildMenu()
    }

    // MARK: - Actions: static fallback

    @objc private func setScreenStaticBlack(_ sender: NSMenuItem) {
        let screen = NSScreen.screens[sender.tag]
        controller.setStaticWallpaper(nil, for: screen.localizedName)
        if controller.activeSources[screen.localizedName] == nil {
            controller.applyStaticWallpaper(for: screen)
        }
    }

    @objc private func setScreenStaticImage(_ sender: NSMenuItem) {
        guard let url = pickFile(types: [.image, .png, .jpeg, .tiff, .heic, .bmp, .webP],
                                  title: L.selectImageTitle) else { return }
        let screen = NSScreen.screens[sender.tag]
        controller.setStaticWallpaper(url, for: screen.localizedName)
        if controller.activeSources[screen.localizedName] == nil {
            controller.applyStaticWallpaper(for: screen)
        }
    }

    @objc private func setStaticForAll() {
        guard let url = pickFile(types: [.image, .png, .jpeg, .tiff, .heic, .bmp, .webP],
                                  title: L.selectImageTitle) else { return }
        for screen in NSScreen.screens {
            controller.setStaticWallpaper(url, for: screen.localizedName)
            if controller.activeSources[screen.localizedName] == nil {
                controller.applyStaticWallpaper(for: screen)
            }
        }
    }

    // MARK: - Quit

    @objc private func quit() {
        // Let applicationWillTerminate handle persist + static fallback —
        // terminate() triggers it synchronously.
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
}

// MARK: - Menu delegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshDynamicMenu()
        refreshStaticMenu()
    }
}
