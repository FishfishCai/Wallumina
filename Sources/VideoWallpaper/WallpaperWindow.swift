import AppKit
import AVFoundation
import WebKit

@MainActor
func createWallpaperWindow(screen: NSScreen) -> NSWindow {
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
    return window
}

@MainActor
func setupVideoContent(window: NSWindow, screen: NSScreen, path: String) -> AVPlayer {
    let player = AVPlayer(url: URL(fileURLWithPath: path))
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

    player.play()
    return player
}

@MainActor
func setupWebContent(window: NSWindow, screen: NSScreen, fileURL: URL, propertyJS: String?) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

    // Inject WE property call that polls until BOTH the listener AND the scene are ready.
    // wallpaperPropertyListener exists at parse time, but cl() needs init() to have
    // created scene/renderer/material first (init runs on onLoad).
    if let js = propertyJS {
        let pollScript = """
            (function _vwPoll() {
                if (window.wallpaperPropertyListener &&
                    window.wallpaperPropertyListener.applyUserProperties &&
                    window.renderer) {
                    window.wallpaperPropertyListener.applyUserProperties(\(js));
                } else {
                    setTimeout(_vwPoll, 200);
                }
            })();
            """
        let userScript = WKUserScript(source: pollScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)
    }

    let webView = WKWebView(frame: CGRect(origin: .zero, size: screen.frame.size), configuration: config)
    webView.setValue(false, forKey: "drawsBackground")
    webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    window.contentView = webView

    return webView
}
