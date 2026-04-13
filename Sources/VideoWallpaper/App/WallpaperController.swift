import AppKit
import AVFoundation
import WebKit

/// Owns all per-screen wallpaper state and orchestrates the four backends.
/// AppDelegate talks to this; menu items are pure UI that read/write here.
@MainActor
final class WallpaperController {
    // MARK: - Per-screen state

    private var wallpaperWindows: [String: NSWindow] = [:]
    private var players: [String: AVPlayer] = [:]
    private var webViews: [String: WKWebView] = [:]
    #if ENABLE_SCENE
    private var sceneEngines: [String: SceneEngine] = [:]
    #endif
    private(set) var activeSources: [String: WallpaperSource] = [:]
    private(set) var lastSources: [String: WallpaperSource] = [:]
    private(set) var staticWallpapers: [String: URL] = [:]
    private(set) var pausedScreens: Set<String> = []
    private var webPropertyJS: [String: String] = [:]

    private var audioMuted = false
    var isAudioMuted: Bool { audioMuted }

    // MARK: - Show / teardown

    /// Show a wallpaper on a specific screen. Tears down any existing one on that screen first.
    func show(on screen: NSScreen, source: WallpaperSource, propertyJS: String? = nil) {
        let name = screen.localizedName
        teardown(name: name)
        try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])

        if let js = propertyJS { webPropertyJS[name] = js }

        let window = createWallpaperWindow(screen: screen)

        switch source.type {
        case .video:
            players[name] = setupVideoContent(window: window, screen: screen, path: source.path)
        case .web:
            webViews[name] = setupWebContent(
                window: window, screen: screen,
                fileURL: URL(fileURLWithPath: source.path),
                propertyJS: webPropertyJS[name]
            )
        case .scene:
            #if ENABLE_SCENE
            sceneEngines[name] = setupSceneContent(
                window: window, screen: screen,
                folderURL: URL(fileURLWithPath: source.path)
            )
            // Inherit the current mute state — otherwise a newly-loaded scene
            // would start at default volume even if the user already muted.
            sceneEngines[name]?.setMuted(audioMuted)
            #else
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

    /// Stop one screen's active wallpaper. Restores the static fallback on that screen.
    func stop(screen: NSScreen) {
        let name = screen.localizedName
        if let s = activeSources[name] { lastSources[name] = s }
        teardown(name: name)
        activeSources.removeValue(forKey: name)
        pausedScreens.remove(name)
        applyStaticWallpaper(for: screen)
    }

    /// Stop every active screen and apply static fallback everywhere.
    func stopAllActive() {
        for (n, s) in activeSources { lastSources[n] = s }
        for n in activeSources.keys { teardown(name: n) }
        activeSources.removeAll()
        pausedScreens.removeAll()
        applyStaticToAllScreens()
    }

    /// Restore the last-known wallpaper for one screen (used for "Restore" menu item).
    func restoreLast(on screen: NSScreen) {
        guard let source = lastSources[screen.localizedName] else { return }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        show(on: screen, source: source)
    }

    /// Restore every screen that has a lastSource but no active wallpaper.
    func resumeAllLast() {
        for screen in NSScreen.screens {
            let name = screen.localizedName
            if activeSources[name] != nil { continue }
            guard let source = lastSources[name],
                  FileManager.default.fileExists(atPath: source.path) else { continue }
            show(on: screen, source: source)
        }
    }

    private func teardown(name: String) {
        players[name]?.pause()
        players.removeValue(forKey: name)
        webViews.removeValue(forKey: name)
        #if ENABLE_SCENE
        sceneEngines.removeValue(forKey: name)
        #endif
        wallpaperWindows[name]?.orderOut(nil)
        wallpaperWindows.removeValue(forKey: name)
    }

    // MARK: - Pause

    func isPaused(_ name: String) -> Bool { pausedScreens.contains(name) }

    func setPaused(_ paused: Bool, for name: String) {
        if paused {
            pausedScreens.insert(name)
            players[name]?.pause()
            webViews[name]?.evaluateJavaScript(
                "document.querySelectorAll('video,audio').forEach(v=>v.pause())",
                completionHandler: nil)
            #if ENABLE_SCENE
            sceneEngines[name]?.setPaused(true)
            #endif
        } else {
            pausedScreens.remove(name)
            players[name]?.play()
            webViews[name]?.evaluateJavaScript(
                "document.querySelectorAll('video,audio').forEach(v=>v.play())",
                completionHandler: nil)
            #if ENABLE_SCENE
            sceneEngines[name]?.setPaused(false)
            #endif
        }
    }

    func togglePause(for name: String) {
        setPaused(!isPaused(name), for: name)
    }

    /// Pause or resume all active screens together.
    func toggleAllPaused() {
        let shouldPause = !activeSources.keys.allSatisfy { pausedScreens.contains($0) }
        for name in activeSources.keys { setPaused(shouldPause, for: name) }
    }

    // MARK: - Audio

    func setAudioMuted(_ muted: Bool) {
        audioMuted = muted
        #if ENABLE_SCENE
        for engine in sceneEngines.values { engine.setMuted(muted) }
        #endif
    }

    // MARK: - Mouse forwarding

    /// Broadcast a global NSEvent to every active web view and scene engine that contains the cursor.
    func injectMouseEvent(_ event: NSEvent) {
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
            guard pt.x >= 0, pt.x <= window.frame.width,
                  pt.y >= 0, pt.y <= window.frame.height else { continue }
            webView.evaluateJavaScript(
                "(function(){var el=document.elementFromPoint(\(pt.x),\(y))||document;el.dispatchEvent(new MouseEvent('\(jsEvent)',{clientX:\(pt.x),clientY:\(y),bubbles:true}))})();",
                completionHandler: nil
            )
        }
        #if ENABLE_SCENE
        for (name, engine) in sceneEngines {
            guard let window = wallpaperWindows[name] else { continue }
            let pt = window.convertPoint(fromScreen: loc)
            guard pt.x >= 0, pt.x <= window.frame.width,
                  pt.y >= 0, pt.y <= window.frame.height else { continue }
            engine.updateMouse(Float(pt.x / window.frame.width),
                               Float(1 - pt.y / window.frame.height))
        }
        #endif
    }

    // MARK: - Static wallpaper (idle fallback)

    func setStaticWallpaper(_ url: URL?, for name: String) {
        if let url { staticWallpapers[name] = url }
        else { staticWallpapers.removeValue(forKey: name) }
    }

    func applyStaticWallpaper(for screen: NSScreen) {
        let url = staticWallpapers[screen.localizedName] ?? blackImageURL
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
    }

    func applyStaticToAllScreens() {
        NSScreen.screens.forEach { applyStaticWallpaper(for: $0) }
    }

    func applyStaticToInactiveScreens() {
        for screen in NSScreen.screens where activeSources[screen.localizedName] == nil {
            applyStaticWallpaper(for: screen)
        }
    }

    /// macOS sometimes resets the desktop image shortly after launch; this forces
    /// active screens back to the black placeholder so the real wallpaper shows through.
    func enforceBlackOnActiveScreens() {
        for screen in NSScreen.screens where activeSources[screen.localizedName] != nil {
            try? NSWorkspace.shared.setDesktopImageURL(blackImageURL, for: screen, options: [:])
        }
    }

    // MARK: - Persistence

    func persist() {
        var config = AppConfig(screens: [:])
        let allNames = Set(activeSources.keys)
            .union(lastSources.keys)
            .union(staticWallpapers.keys)
            .union(NSScreen.screens.map { $0.localizedName })
        for name in allNames {
            config.screens[name] = ScreenConfig(
                wallpaperSource: activeSources[name] ?? lastSources[name],
                paused: pausedScreens.contains(name),
                staticWallpaperPath: staticWallpapers[name]?.path,
                webPropertyJS: webPropertyJS[name]
            )
        }
        saveConfig(config)
    }

    func restore() {
        let config = loadConfig()
        for (name, sc) in config.screens {
            if let p = sc.staticWallpaperPath, FileManager.default.fileExists(atPath: p) {
                staticWallpapers[name] = URL(fileURLWithPath: p)
            }
            if let source = sc.wallpaperSource {
                lastSources[name] = source
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else { continue }
                // Restore the WE user-properties blob BEFORE show() — otherwise the web view
                // boots with defaults and the user's toggles are lost.
                show(on: screen, source: source, propertyJS: sc.webPropertyJS)
                if sc.paused {
                    // Go through the real pause path so web/scene actually pause, not just .video
                    setPaused(true, for: name)
                }
            }
        }
    }
}
