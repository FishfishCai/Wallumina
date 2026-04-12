import Foundation
import AppKit

// MARK: - Types

enum WallpaperType: String, Codable {
    case video
    case web
}

struct WallpaperSource: Codable {
    var type: WallpaperType
    var path: String

    var displayName: String {
        switch type {
        case .video: return URL(fileURLWithPath: path).lastPathComponent
        case .web: return "🌐 " + URL(fileURLWithPath: path).lastPathComponent
        }
    }
}

// MARK: - Config

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

// MARK: - Wallpaper Engine

struct WEProject: Decodable {
    let type: String?
    let file: String?
    let title: String?
    let general: WEGeneral?
}

struct WEGeneral: Decodable {
    let properties: [String: WEProperty]?
}

struct WEProperty: Decodable {
    let type: String?
    let value: WEValue?
}

enum WEValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .string("") }
    }

    var jsValue: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

/// Build a JS object literal with WE default property values
func buildWEPropertiesJSON(from project: WEProject) -> String? {
    guard let props = project.general?.properties, !props.isEmpty else { return nil }
    var entries: [String] = []
    for (key, prop) in props {
        let jsVal = prop.value?.jsValue ?? "\"\""
        entries.append("\"\(key)\":{\"value\":\(jsVal)}")
    }
    return "{\(entries.joined(separator: ","))}"
}

struct WEParseResult {
    let source: WallpaperSource
    let title: String
    let propertyJS: String?
}

func parseWEProject(at folderURL: URL) -> WEParseResult? {
    let projectFile = folderURL.appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: projectFile),
          let project = try? JSONDecoder().decode(WEProject.self, from: data),
          let type = project.type?.lowercased(),
          let file = project.file else { return nil }

    let filePath = folderURL.appendingPathComponent(file).path
    let title = project.title ?? folderURL.lastPathComponent

    switch type {
    case "video":
        return WEParseResult(source: WallpaperSource(type: .video, path: filePath), title: title, propertyJS: nil)
    case "web":
        let propsJSON = buildWEPropertiesJSON(from: project)
        return WEParseResult(source: WallpaperSource(type: .web, path: filePath), title: title, propertyJS: propsJSON)
    default:
        return nil
    }
}
