import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Localization

enum Lang: String, Codable {
    case zh, en
}

@MainActor
struct L {
    static var lang: Lang = .en

    static var dynamicScreens: String { lang == .zh ? "屏幕动态壁纸" : "Screen Video Wallpaper" }
    static var staticScreens: String { lang == .zh ? "屏幕静态壁纸" : "Screen Static Wallpaper" }
    static var setDynamicAll: String { lang == .zh ? "统一设置动态壁纸…" : "Set Video for All…" }
    static var setStaticAll: String { lang == .zh ? "统一设置静态壁纸…" : "Set Static for All…" }
    static var pauseResumeAll: String { lang == .zh ? "全部暂停/继续" : "Pause/Resume All" }
    static var stopAll: String { lang == .zh ? "全部停止" : "Stop All" }
    static var resumeAll: String { lang == .zh ? "全部恢复" : "Resume All" }
    static var solidBlack: String { lang == .zh ? "纯黑" : "Solid Black" }
    static var chooseImage: String { lang == .zh ? "选择图片…" : "Choose Image…" }
    static var language: String { lang == .zh ? "语言" : "Language" }
    static var quit: String { lang == .zh ? "退出" : "Quit" }
    static var selectVideo: String { lang == .zh ? "选择视频…" : "Select Video…" }
    static var pause: String { lang == .zh ? "暂停" : "Pause" }
    static var resume: String { lang == .zh ? "继续" : "Resume" }
    static var stop: String { lang == .zh ? "停止" : "Stop" }
    static var restore: String { lang == .zh ? "恢复" : "Restore" }
    static var selectVideoTitle: String { lang == .zh ? "选择视频文件" : "Select Video File" }
    static var selectImageTitle: String { lang == .zh ? "选择壁纸图片" : "Select Wallpaper Image" }
    static var current: String { lang == .zh ? "当前" : "Current" }
}

// MARK: - Config

private let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/VideoWallpaper")
private let configFile = configDir.appendingPathComponent("state.json")
private let langFile = configDir.appendingPathComponent("lang.json")
private let blackImageURL = configDir.appendingPathComponent("black.png")

struct AppConfig: Codable {
    var screens: [String: ScreenConfig]
}

struct ScreenConfig: Codable {
    var videoPath: String?
    var paused: Bool
    var staticWallpaperPath: String?
}

@MainActor
func loadConfig() -> AppConfig {
    guard let data = try? Data(contentsOf: configFile),
          let config = try? JSONDecoder().decode(AppConfig.self, from: data)
    else { return AppConfig(screens: [:]) }
    return config
}

@MainActor
func saveConfig(_ config: AppConfig) {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(config) {
        try? data.write(to: configFile)
    }
}

@MainActor
func loadLang() -> Lang {
    guard let data = try? Data(contentsOf: langFile),
          let lang = try? JSONDecoder().decode(Lang.self, from: data)
    else { return .en }
    return lang
}

@MainActor
func saveLang(_ lang: Lang) {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(lang) {
        try? data.write(to: langFile)
    }
}

@MainActor
func ensureBlackImage() {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: blackImageURL.path) { return }
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    if let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: blackImageURL)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var wallpaperWindows: [String: NSWindow] = [:]
    private var players: [String: AVPlayer] = [:]
    private var videoURLs: [String: URL] = [:]
    private var lastVideoURLs: [String: URL] = [:]
    private var staticWallpapers: [String: URL] = [:]
    private var pausedScreens: Set<String> = []
    private var dynamicMenu: NSMenu!
    private var staticMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureBlackImage()
        L.lang = loadLang()
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])
        }
        setupMenuBar()
        restoreConfig()
        applyStaticToInactiveScreens()
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforceBlackOnActiveScreens()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistConfig()
        applyStaticToAllScreens()
    }

    // MARK: - Config Persistence

    private func persistConfig() {
        var config = AppConfig(screens: [:])
        let allNames = Set(videoURLs.keys)
            .union(lastVideoURLs.keys)
            .union(staticWallpapers.keys)
            .union(NSScreen.screens.map { $0.localizedName })

        for name in allNames {
            let videoPath = (videoURLs[name] ?? lastVideoURLs[name])?.path
            config.screens[name] = ScreenConfig(
                videoPath: videoPath,
                paused: pausedScreens.contains(name),
                staticWallpaperPath: staticWallpapers[name]?.path
            )
        }
        saveConfig(config)
    }

    private func restoreConfig() {
        let config = loadConfig()
        for (name, sc) in config.screens {
            if let path = sc.staticWallpaperPath {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    staticWallpapers[name] = url
                }
            }
            if let path = sc.videoPath {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                lastVideoURLs[name] = url
                guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else { continue }
                playOnScreen(screen: screen, url: url)
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
        menu.addItem(NSMenuItem(title: L.setDynamicAll, action: #selector(selectVideoForAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L.setStaticAll, action: #selector(setStaticForAll), keyEquivalent: ""))
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
            let label = "\(name) (\(index + 1))"

            let screenItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let sub = NSMenu()

            if let url = videoURLs[name] {
                let status = pausedScreens.contains(name) ? "⏸" : "▶"
                let info = NSMenuItem(title: "\(status) \(url.lastPathComponent)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                sub.addItem(info)
                sub.addItem(NSMenuItem.separator())
            }

            let selectItem = NSMenuItem(title: L.selectVideo, action: #selector(selectVideoForScreen(_:)), keyEquivalent: "")
            selectItem.tag = index
            sub.addItem(selectItem)

            if videoURLs[name] != nil {
                let pauseTitle = pausedScreens.contains(name) ? L.resume : L.pause
                let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePauseScreen(_:)), keyEquivalent: "")
                pauseItem.tag = index
                sub.addItem(pauseItem)

                let stopItem = NSMenuItem(title: L.stop, action: #selector(stopScreen(_:)), keyEquivalent: "")
                stopItem.tag = index
                sub.addItem(stopItem)
            }

            if videoURLs[name] == nil, let lastURL = lastVideoURLs[name] {
                let restoreItem = NSMenuItem(title: "\(L.restore) (\(lastURL.lastPathComponent))", action: #selector(restoreScreen(_:)), keyEquivalent: "")
                restoreItem.tag = index
                sub.addItem(restoreItem)
            }

            screenItem.submenu = sub
            dynamicMenu.addItem(screenItem)
        }
    }

    private func refreshStaticMenu() {
        staticMenu.removeAllItems()
        for (index, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let label = "\(name) (\(index + 1))"

            let screenItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let sub = NSMenu()

            let currentName = staticWallpapers[name]?.lastPathComponent ?? L.solidBlack
            let info = NSMenuItem(title: "\(L.current): \(currentName)", action: nil, keyEquivalent: "")
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

    @objc private func setLangZh() {
        L.lang = .zh
        saveLang(.zh)
        rebuildMenu()
    }

    @objc private func setLangEn() {
        L.lang = .en
        saveLang(.en)
        rebuildMenu()
    }

    // MARK: - Dynamic Wallpaper Actions

    @objc private func selectVideoForScreen(_ sender: NSMenuItem) {
        let index = sender.tag
        let screens = NSScreen.screens
        guard index < screens.count else { return }
        guard let url = pickVideoFile() else { return }
        playOnScreen(screen: screens[index], url: url)
    }

    @objc private func selectVideoForAll() {
        guard let url = pickVideoFile() else { return }
        for screen in NSScreen.screens {
            playOnScreen(screen: screen, url: url)
        }
    }

    @objc private func togglePauseScreen(_ sender: NSMenuItem) {
        let index = sender.tag
        let screens = NSScreen.screens
        guard index < screens.count else { return }
        let name = screens[index].localizedName
        guard let player = players[name] else { return }

        if pausedScreens.contains(name) {
            pausedScreens.remove(name)
            player.play()
        } else {
            pausedScreens.insert(name)
            player.pause()
        }
    }

    @objc private func togglePauseAll() {
        let allPaused = players.keys.allSatisfy { pausedScreens.contains($0) }
        for (name, player) in players {
            if allPaused {
                pausedScreens.remove(name)
                player.play()
            } else {
                pausedScreens.insert(name)
                player.pause()
            }
        }
    }

    @objc private func stopScreen(_ sender: NSMenuItem) {
        let index = sender.tag
        let screens = NSScreen.screens
        guard index < screens.count else { return }
        let screen = screens[index]
        let name = screen.localizedName

        players[name]?.pause()
        players.removeValue(forKey: name)
        wallpaperWindows[name]?.orderOut(nil)
        wallpaperWindows.removeValue(forKey: name)
        if let url = videoURLs[name] {
            lastVideoURLs[name] = url
        }
        videoURLs.removeValue(forKey: name)
        pausedScreens.remove(name)

        applyStaticWallpaper(for: screen)
    }

    @objc private func stopAll() {
        for (name, url) in videoURLs {
            lastVideoURLs[name] = url
        }
        for player in players.values { player.pause() }
        players.removeAll()
        for window in wallpaperWindows.values { window.orderOut(nil) }
        wallpaperWindows.removeAll()
        videoURLs.removeAll()
        pausedScreens.removeAll()
        applyStaticToAllScreens()
    }

    @objc private func restoreScreen(_ sender: NSMenuItem) {
        let index = sender.tag
        let screens = NSScreen.screens
        guard index < screens.count else { return }
        let name = screens[index].localizedName
        guard let url = lastVideoURLs[name],
              FileManager.default.fileExists(atPath: url.path) else { return }
        playOnScreen(screen: screens[index], url: url)
    }

    @objc private func resumeAll() {
        for screen in NSScreen.screens {
            let name = screen.localizedName
            if videoURLs[name] != nil { continue }
            guard let url = lastVideoURLs[name],
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            playOnScreen(screen: screen, url: url)
        }
    }

    // MARK: - Static Wallpaper Actions

    @objc private func setScreenStaticBlack(_ sender: NSMenuItem) {
        let index = sender.tag
        let screens = NSScreen.screens
        guard index < screens.count else { return }
        let name = screens[index].localizedName
        staticWallpapers.removeValue(forKey: name)
        if videoURLs[name] == nil {
            applyStaticWallpaper(for: screens[index])
        }
    }

    @objc private func setScreenStaticImage(_ sender: NSMenuItem) {
        let index = sender.tag
        let screens = NSScreen.screens
        guard index < screens.count else { return }
        guard let url = pickImageFile() else { return }
        let name = screens[index].localizedName
        staticWallpapers[name] = url
        if videoURLs[name] == nil {
            applyStaticWallpaper(for: screens[index])
        }
    }

    @objc private func setStaticForAll() {
        guard let url = pickImageFile() else { return }
        for screen in NSScreen.screens {
            let name = screen.localizedName
            staticWallpapers[name] = url
            if videoURLs[name] == nil {
                applyStaticWallpaper(for: screen)
            }
        }
    }

    // MARK: - File Pickers

    private func pickVideoFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.quickTimeMovie, UTType.avi, UTType.mpeg2Video, UTType.appleProtectedMPEG4Video]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L.selectVideoTitle
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func pickImageFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.image, UTType.png, UTType.jpeg, UTType.tiff, UTType.heic, UTType.bmp, UTType.webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L.selectImageTitle
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Quit

    @objc private func quit() {
        persistConfig()
        for player in players.values { player.pause() }
        players.removeAll()
        for window in wallpaperWindows.values { window.orderOut(nil) }
        wallpaperWindows.removeAll()
        applyStaticToAllScreens()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Wallpaper Apply

    private func applyStaticWallpaper(for screen: NSScreen) {
        let name = screen.localizedName
        let url = staticWallpapers[name] ?? blackImageURL
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
    }

    private func applyStaticToAllScreens() {
        for screen in NSScreen.screens {
            applyStaticWallpaper(for: screen)
        }
    }

    private func applyStaticToInactiveScreens() {
        for screen in NSScreen.screens {
            let name = screen.localizedName
            if videoURLs[name] == nil {
                applyStaticWallpaper(for: screen)
            }
        }
    }

    private func enforceBlackOnActiveScreens() {
        for screen in NSScreen.screens {
            let name = screen.localizedName
            if videoURLs[name] != nil {
                try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])
            }
        }
    }

    // MARK: - Video Wallpaper Window

    private func playOnScreen(screen: NSScreen, url: URL) {
        let name = screen.localizedName

        players[name]?.pause()
        wallpaperWindows[name]?.orderOut(nil)

        try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black

        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = CGRect(origin: .zero, size: screen.frame.size)

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.addSublayer(playerLayer)
        window.contentView = view

        window.orderFront(nil)
        player.play()

        wallpaperWindows[name] = window
        players[name] = player
        videoURLs[name] = url
        lastVideoURLs[name] = url
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

// MARK: - Main

@MainActor
func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

MainActor.assumeIsolated {
    runApp()
}
