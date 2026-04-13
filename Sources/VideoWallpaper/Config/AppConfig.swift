import Foundation
import AppKit

// MARK: - Wallpaper source

enum WallpaperType: String, Codable {
    case video
    case web
    case scene
    case image
}

struct WallpaperSource: Codable {
    var type: WallpaperType
    var path: String
    var title: String?

    var displayName: String {
        if let title, !title.isEmpty { return title }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - On-disk config

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/VideoWallpaper")
let configFile = configDir.appendingPathComponent("state.json")
let langFile = configDir.appendingPathComponent("lang.json")
let blackImageURL = configDir.appendingPathComponent("black.png")

struct AppConfig: Codable {
    var screens: [String: ScreenConfig]
}

struct ScreenConfig: Codable {
    var wallpaperSource: WallpaperSource?
    var paused: Bool
    var staticWallpaperPath: String?
    /// Wallpaper Engine user-property JS object literal for web wallpapers.
    /// Optional so old state.json files still decode.
    var webPropertyJS: String?
}

@MainActor
func loadConfig() -> AppConfig {
    guard let data = try? Data(contentsOf: configFile),
          var config = try? JSONDecoder().decode(AppConfig.self, from: data)
    else { return AppConfig(screens: [:]) }

    #if !ENABLE_SCENE
    // Stable build: drop any persisted scene wallpapers so we don't try to restore them.
    for (name, sc) in config.screens where sc.wallpaperSource?.type == .scene {
        var copy = sc
        copy.wallpaperSource = nil
        config.screens[name] = copy
    }
    #endif

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
