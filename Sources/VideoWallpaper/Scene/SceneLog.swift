#if ENABLE_SCENE
import os.log

/// Shared `os.Logger` instances for the scene subsystem. Routed to Console.app
/// under the "com.fishfishcai.VideoWallpaper" subsystem; filter by category.
enum SceneLog {
    private static let subsystem = "com.fishfishcai.VideoWallpaper"
    static let shader = Logger(subsystem: subsystem, category: "scene.shader")
    static let audio  = Logger(subsystem: subsystem, category: "scene.audio")
    static let script = Logger(subsystem: subsystem, category: "scene.script")
}
#endif
