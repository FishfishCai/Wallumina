import Foundation

// MARK: - project.json models

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
          let type = project.type?.lowercased() else { return nil }

    let title = project.title ?? folderURL.lastPathComponent

    switch type {
    case "video":
        guard let file = project.file else { return nil }
        let filePath = folderURL.appendingPathComponent(file).path
        return WEParseResult(source: WallpaperSource(type: .video, path: filePath, title: title),
                             title: title, propertyJS: nil)
    case "web":
        guard let file = project.file else { return nil }
        let filePath = folderURL.appendingPathComponent(file).path
        let propsJSON = buildWEPropertiesJSON(from: project)
        return WEParseResult(source: WallpaperSource(type: .web, path: filePath, title: title),
                             title: title, propertyJS: propsJSON)
    case "scene":
        #if ENABLE_SCENE
        return parseWEScene(at: folderURL, project: project, title: title)
        #else
        return nil
        #endif
    default:
        return nil
    }
}
