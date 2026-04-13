import AppKit

@MainActor
func setupImageContent(window: NSWindow, screen: NSScreen, path: String) {
    let imageView = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
    imageView.image = NSImage(contentsOfFile: path)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    window.contentView = imageView
}
