#if ENABLE_SCENE
import AppKit
import MetalKit

@MainActor
func setupSceneContent(window: NSWindow, screen: NSScreen, folderURL: URL) -> SceneEngine? {
    // Parse WE folder straight into an in-memory bundle. No disk metadata.json,
    // no intermediate PNGs — textures arrive as CGImages.
    guard let bundle = loadSceneBundle(folderURL: folderURL) else { return nil }

    let mtkView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size))
    mtkView.layer?.isOpaque = true
    mtkView.preferredFramesPerSecond = 60

    guard let engine = SceneEngine(mtkView: mtkView) else { return nil }
    engine.configure(with: bundle)

    window.contentView = mtkView
    return engine
}
#endif
