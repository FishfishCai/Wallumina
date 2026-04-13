import AppKit
import AVFoundation

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
