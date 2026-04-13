import AppKit
import WebKit

@MainActor
func setupWebContent(window: NSWindow, screen: NSScreen, fileURL: URL, propertyJS: String?) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

    // Poll until BOTH the WE property listener AND the renderer exist.
    // The listener is created at parse time; the renderer is only created
    // inside the wallpaper's init() which runs on onLoad.
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
