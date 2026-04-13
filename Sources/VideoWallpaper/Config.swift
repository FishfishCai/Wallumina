import Foundation
import AppKit

// MARK: - Types

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
          let type = project.type?.lowercased() else { return nil }

    let title = project.title ?? folderURL.lastPathComponent

    switch type {
    case "video":
        guard let file = project.file else { return nil }
        let filePath = folderURL.appendingPathComponent(file).path
        return WEParseResult(source: WallpaperSource(type: .video, path: filePath, title: title), title: title, propertyJS: nil)
    case "web":
        guard let file = project.file else { return nil }
        let filePath = folderURL.appendingPathComponent(file).path
        let propsJSON = buildWEPropertiesJSON(from: project)
        return WEParseResult(source: WallpaperSource(type: .web, path: filePath, title: title), title: title, propertyJS: propsJSON)
    case "scene":
        return parseWEScene(at: folderURL, project: project, title: title)
    default:
        return nil
    }
}

// MARK: - Scene Support

/// Extract files from PKGV binary package (all versions)
func extractPKG(at url: URL) -> [String: Data]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let bytes = [UInt8](data)
    guard bytes.count > 16 else { return nil }

    func u32(_ off: Int) -> UInt32 {
        guard off + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[off]) | (UInt32(bytes[off+1]) << 8) |
               (UInt32(bytes[off+2]) << 16) | (UInt32(bytes[off+3]) << 24)
    }

    // Header is a length-prefixed string: uint32 len + "PKGV####"
    var pos = 0
    let headerLen = Int(u32(pos)); pos += 4
    guard headerLen >= 8, pos + headerLen <= bytes.count else { return nil }
    let header = String(bytes: bytes[pos..<pos+min(headerLen, 8)], encoding: .ascii) ?? ""
    guard header.hasPrefix("PKGV") else { return nil }
    pos += headerLen

    // File count
    let count = Int(u32(pos)); pos += 4

    // Read entries: each is length-prefixed string + offset + size
    var entries: [(String, Int, Int)] = []
    for _ in 0..<count {
        guard pos + 4 <= bytes.count else { return nil }
        let nameLen = Int(u32(pos)); pos += 4
        guard pos + nameLen + 8 <= bytes.count else { return nil }
        let name = String(bytes: bytes[pos..<pos+nameLen], encoding: .utf8) ?? ""
        pos += nameLen
        let offset = Int(u32(pos)); pos += 4
        let size = Int(u32(pos)); pos += 4
        entries.append((name, offset, size))
    }

    let dataStart = pos
    var result: [String: Data] = [:]
    for (name, offset, size) in entries {
        let start = dataStart + offset
        guard start >= 0, size >= 0, start + size <= bytes.count else { continue }
        result[name] = Data(bytes[start..<start+size])
    }
    return result
}

// Scene JSON models

struct WEScene: Decodable {
    let camera: WECamera?
    let general: WESceneGeneral?
    let objects: [WESceneObject]?
}

struct WECamera: Decodable {
    let center: String?
    let eye: String?
}

struct WESceneGeneral: Decodable {
    let orthogonalprojection: WEOrtho?
    let cameraparallax: Bool?
    let cameraparallaxamount: Double?
    let cameraparallaxdelay: Double?
    let cameraparallaxmouseinfluence: Double?
    let clearcolor: String?
    let bloom: Bool?
    let bloomstrength: Double?
    let bloomthreshold: Double?
}

struct WEOrtho: Decodable {
    let width: Int
    let height: Int
}

struct WESceneObject: Decodable {
    let id: Int?
    let name: String?
    let image: String?
    let particle: String?
    let origin: String?
    let size: String?
    let angles: String?
    let scale: String?
    let visible: WEFlexBool?
    let parallaxDepth: String?
    let effects: [WEEffect]?
    let instanceoverride: WEInstanceOverride?
    let dependencies: [Int]?
}

/// Handles `visible` field that can be bool, string, or dict {"user":..., "value":bool}
enum WEFlexBool: Decodable {
    case bool(Bool)

    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        // Try single value first (bool, int, string)
        if let c = try? decoder.singleValueContainer() {
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Int.self) { self = .bool(v != 0); return }
            if let _ = try? c.decode(String.self) { self = .bool(true); return }
        }
        // Try keyed container (dict with "value" key)
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            if let v = try? c.decode(Bool.self, forKey: .value) { self = .bool(v); return }
        }
        self = .bool(true)
    }

    var value: Bool {
        switch self { case .bool(let b): return b }
    }
}

struct WEEffect: Decodable {
    let id: Int?
    let file: String?
    let name: String?
    let passes: [WEEffectPass]?
    let visible: WEFlexBool?
    // inline constant values
    let animationspeed: Double?
    let speed: Double?
    let strength: Double?
    let scale: Double?
    let ripplestrength: Double?
    let scrollspeed: Double?
    let scrolldirection: Double?
    let ratio: Double?
}

struct WEEffectPass: Decodable {
    let material: String?
    let constantshadervalues: [String: WEFlexDouble]?
    let textures: [String?]?  // per-index texture paths (null = framebuffer/default)
}

struct WEInstanceOverride: Decodable {
    let size: WEFlexDouble?
    let alpha: WEFlexDouble?
    let rate: WEFlexDouble?
    let speed: WEFlexDouble?
    let count: WEFlexDouble?
}

/// Handles values that can be a number or a dict {"user":..., "value": number}
enum WEFlexDouble: Decodable {
    case number(Double)

    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if let v = try? c.decode(Double.self) { self = .number(v); return }
            if let v = try? c.decode(Int.self) { self = .number(Double(v)); return }
        }
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            if let v = try? c.decode(Double.self, forKey: .value) { self = .number(v); return }
        }
        self = .number(0)
    }

    var value: Double {
        switch self { case .number(let d): return d }
    }
}

struct WEParticle: Decodable {
    let emitter: [WEEmitter]?
    let initializer: [WEInitializer]?
    let material: String?
    let maxcount: Int?
    let starttime: Double?
    let `operator`: [WEOperator]?
    let renderer: [WERenderer]?
}

struct WERenderer: Decodable {
    let name: String?
    let id: Int?
}

struct WEEmitter: Decodable {
    let name: String?
    let origin: String?
    let rate: Double?
    let distancemax: WENumOrString?
    let distancemin: WENumOrString?
    let directions: String?
    let speedmax: Double?
}

struct WEInitializer: Decodable {
    let name: String?
    let min: WENumOrString?
    let max: WENumOrString?
}

struct WEOperator: Decodable {
    let name: String?
    let gravity: String?
    let drag: Double?
    let fadeintime: Double?
    let fadeouttime: Double?
    let frequencymin: Double?
    let frequencymax: Double?
    let scalemin: Double?
    let scalemax: Double?
    let mask: String?
    let startvalue: Double?
    let endvalue: Double?
    let scale: WENumOrString?
    let threshold: Double?
}

enum WENumOrString: Decodable {
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .number(0) }
    }

    var doubleValue: Double {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s.split(separator: " ").first ?? "") ?? 0
        }
    }
}

struct SceneMetadata: Codable {
    let sceneWidth: Int
    let sceneHeight: Int
    let backgroundPath: String?
    let parallax: Bool
    let parallaxAmount: Double
    let parallaxDelay: Double
    let particles: [ParticleConfig]
    let effects: [EffectConfig]       // flat list (legacy, used when layers is nil)
    let layers: [LayerConfig]?        // per-layer config with effects
    let bloomEnabled: Bool?
    let bloomStrength: Double?
    let bloomThreshold: Double?
    let soundPath: String?
}

struct LayerConfig: Codable {
    let id: Int
    let texturePath: String?
    let originX: Float, originY: Float
    let sizeW: Float, sizeH: Float
    let scaleX: Float, scaleY: Float
    let alpha: Float
    let parallaxX: Float, parallaxY: Float
    let colorBlendMode: Int
    let visible: Bool
    let effects: [EffectConfig]
}

struct EffectConfig: Codable {
    let type: String  // shader name e.g. "effects/waterripple"
    let params: [String: Float]
    let maskTexturePath: String?
    let extraTexturePaths: [String] // additional texture paths (normal maps, phase maps, etc.)
    let vertexShaderSource: String?
    let fragmentShaderSource: String?
}

struct ParticleConfig: Codable {
    var ox: Float, oy: Float
    var emitterOffsetX: Float, emitterOffsetY: Float
    var spawnW: Float, spawnH: Float
    var rate: Float, maxcount: Int
    var sizeMin: Float, sizeMax: Float
    var velXMin: Float, velXMax: Float
    var velYMin: Float, velYMax: Float
    var lifetimeMin: Float, lifetimeMax: Float
    var colorR: Float, colorG: Float, colorB: Float
    var alphaMin: Float, alphaMax: Float
    var fadeIn: Float, fadeOut: Float
    var oscPosAmpMin: Float, oscPosAmpMax: Float
    var oscPosFreqMin: Float, oscPosFreqMax: Float
    var oscAlphaFreqMin: Float, oscAlphaFreqMax: Float
    var oscAlphaScaleMin: Float, oscAlphaScaleMax: Float
    var sizeStart: Float, sizeEnd: Float
    var cursorRepel: Float, cursorThreshold: Float
    var drag: Float
    var starttime: Float
    var soft: Bool
    var additive: Bool
    var turbulenceScale: Float = 0
    var turbulenceSpeed: Float = 0
    var turbulenceStrength: Float = 0
    var vortexStrength: Float = 0
    var vortexSpeed: Float = 0
    var angVelMin: Float = 0
    var angVelMax: Float = 0
    var rendererType: Int = 0  // 0=sprite, 1=rope
}

func buildParticleConfig(obj: WESceneObject, particle: WEParticle, isAdditive: Bool,
                          sceneW: Float, sceneH: Float) -> ParticleConfig {
    let o = parseVec(obj.origin)
    let ox = Float(o[0]) / sceneW, oy = Float(o[1]) / sceneH

    let emitter = particle.emitter?.first
    let eo = parseVec(emitter?.origin)
    let emOx = Float(eo[0]) / sceneW, emOy = Float(eo[1]) / sceneH
    let isBox = emitter?.name == "boxrandom"
    let distMax = Float(emitter?.distancemax?.doubleValue ?? 50)
    let spawnW = isBox ? distMax / sceneW : distMax / sceneW
    let spawnH = isBox ? Float(eo.count > 1 ? max(eo[1], Double(distMax)) : Double(distMax)) / sceneH : distMax / sceneH * 0.3

    let rate = Float(obj.instanceoverride?.rate?.value ?? emitter?.rate ?? 5)
    let maxcount = (obj.instanceoverride?.count != nil ? Int(obj.instanceoverride!.count!.value) : nil) ?? particle.maxcount ?? 100
    let sizeOverride = Float(obj.instanceoverride?.size?.value ?? 1.0)
    let scaleVec = parseVec(obj.scale)
    let objScaleX = Float(scaleVec.count > 0 ? scaleVec[0] : 1)

    var sizeMin: Float = 5, sizeMax: Float = 20
    var velXMin: Float = 0, velXMax: Float = 0, velYMin: Float = 0, velYMax: Float = 0
    var lifetimeMin: Float = 3, lifetimeMax: Float = 8
    var colorR: Float = 255, colorG: Float = 255, colorB: Float = 255
    var alphaMin: Float = 1, alphaMax: Float = 1
    var fadeIn: Float = 0.1, fadeOut: Float = 0.2
    var oscPosAmpMin: Float = 0, oscPosAmpMax: Float = 0, oscPosFreqMin: Float = 0, oscPosFreqMax: Float = 0
    var oscAlphaFreqMin: Float = 0, oscAlphaFreqMax: Float = 0
    var oscAlphaScaleMin: Float = 0, oscAlphaScaleMax: Float = 0
    var sizeStartVal: Float = 1, sizeEndVal: Float = 1
    var cursorRepelScale: Float = 0, cursorRepelThreshold: Float = 0
    var drag: Float = 0
    var angVelMin: Float = 0, angVelMax: Float = 0

    for initer in particle.initializer ?? [] {
        switch initer.name {
        case "sizerandom":
            sizeMin = Float(initer.min?.doubleValue ?? Double(sizeMin))
            sizeMax = Float(initer.max?.doubleValue ?? Double(sizeMax))
        case "velocityrandom":
            if case .string(let s) = initer.min {
                let p = s.split(separator: " ").map { Float($0) ?? 0 }
                velXMin = p.count > 0 ? p[0] : 0; velYMin = p.count > 1 ? p[1] : 0
            }
            if case .string(let s) = initer.max {
                let p = s.split(separator: " ").map { Float($0) ?? 0 }
                velXMax = p.count > 0 ? p[0] : 0; velYMax = p.count > 1 ? p[1] : 0
            }
        case "lifetimerandom":
            lifetimeMin = Float(initer.min?.doubleValue ?? Double(lifetimeMin))
            lifetimeMax = Float(initer.max?.doubleValue ?? Double(lifetimeMax))
        case "colorrandom":
            if case .string(let s) = initer.max {
                let p = s.split(separator: " ").map { Float($0) ?? 255 }
                colorR = p.count > 0 ? p[0] : 255; colorG = p.count > 1 ? p[1] : 255; colorB = p.count > 2 ? p[2] : 255
            }
        case "alpharandom":
            alphaMin = Float(initer.min?.doubleValue ?? Double(alphaMin))
            alphaMax = Float(initer.max?.doubleValue ?? Double(alphaMax))
        case "angularvelocityrandom":
            angVelMin = Float(initer.min?.doubleValue ?? 0)
            angVelMax = Float(initer.max?.doubleValue ?? 0)
        default: break
        }
    }

    var turbScale: Float = 0, turbSpeed: Float = 0, turbStrength: Float = 0
    var vortexStr: Float = 0, vortexSpd: Float = 0

    for op in particle.operator ?? [] {
        switch op.name {
        case "alphafade":
            fadeIn = Float(op.fadeintime ?? Double(fadeIn))
            fadeOut = Float(op.fadeouttime ?? Double(fadeOut))
        case "oscillateposition":
            oscPosAmpMin = Float(op.scalemin ?? 0); oscPosAmpMax = Float(op.scalemax ?? 0)
            oscPosFreqMin = Float(op.frequencymin ?? 0); oscPosFreqMax = Float(op.frequencymax ?? 0)
        case "oscillatealpha":
            oscAlphaFreqMin = Float(op.frequencymin ?? 0); oscAlphaFreqMax = Float(op.frequencymax ?? 0)
            oscAlphaScaleMin = Float(op.scalemin ?? 0); oscAlphaScaleMax = Float(op.scalemax ?? 0)
        case "sizechange":
            sizeStartVal = Float(op.startvalue ?? 1); sizeEndVal = Float(op.endvalue ?? 1)
        case "controlpointattract":
            cursorRepelScale = Float(op.scale?.doubleValue ?? 0)
            cursorRepelThreshold = Float(op.threshold ?? 0)
        case "movement":
            drag = Float(op.drag ?? 0)
        case "turbulence":
            turbScale = Float(op.scalemin ?? op.scalemax ?? 1)
            turbSpeed = Float(op.frequencymin ?? 1)
            turbStrength = Float(op.scalemax ?? op.scalemin ?? 10)
        case "vortex":
            vortexStr = Float(op.scale?.doubleValue ?? 0)
            vortexSpd = Float(op.frequencymin ?? 1)
        default: break
        }
    }

    // Determine renderer type
    let renderer = particle.renderer?.first
    let rendererType: Int
    switch renderer?.name {
    case "rope", "ropetrail": rendererType = 1
    case "spritetrail": rendererType = 2
    default: rendererType = 0
    }

    return ParticleConfig(
        ox: ox, oy: oy,
        emitterOffsetX: emOx, emitterOffsetY: emOy,
        spawnW: spawnW, spawnH: spawnH,
        rate: rate, maxcount: maxcount,
        sizeMin: sizeMin * sizeOverride * objScaleX / sceneW,
        sizeMax: sizeMax * sizeOverride * objScaleX / sceneW,
        velXMin: velXMin / sceneW, velXMax: velXMax / sceneW,
        velYMin: velYMin / sceneH, velYMax: velYMax / sceneH,
        lifetimeMin: lifetimeMin, lifetimeMax: lifetimeMax,
        colorR: colorR / 255, colorG: colorG / 255, colorB: colorB / 255,
        alphaMin: alphaMin, alphaMax: alphaMax,
        fadeIn: fadeIn, fadeOut: fadeOut,
        oscPosAmpMin: oscPosAmpMin / sceneW, oscPosAmpMax: oscPosAmpMax / sceneW,
        oscPosFreqMin: oscPosFreqMin, oscPosFreqMax: oscPosFreqMax,
        oscAlphaFreqMin: oscAlphaFreqMin, oscAlphaFreqMax: oscAlphaFreqMax,
        oscAlphaScaleMin: oscAlphaScaleMin, oscAlphaScaleMax: oscAlphaScaleMax,
        sizeStart: sizeStartVal, sizeEnd: sizeEndVal,
        cursorRepel: cursorRepelScale / sceneW, cursorThreshold: cursorRepelThreshold / sceneW,
        drag: drag, starttime: Float(particle.starttime ?? 0),
        soft: sizeMax * sizeOverride > 80, additive: isAdditive,
        turbulenceScale: turbScale, turbulenceSpeed: turbSpeed, turbulenceStrength: turbStrength / sceneW,
        vortexStrength: vortexStr / sceneW, vortexSpeed: vortexSpd,
        angVelMin: angVelMin, angVelMax: angVelMax,
        rendererType: rendererType
    )
}

func parseWEScene(at folderURL: URL, project: WEProject, title: String) -> WEParseResult? {
    let pkgFile = folderURL.appendingPathComponent("scene.pkg")
    let sceneDir = configDir.appendingPathComponent("scene_cache/\(folderURL.lastPathComponent)")
    try? FileManager.default.removeItem(at: sceneDir)
    try? FileManager.default.createDirectory(at: sceneDir, withIntermediateDirectories: true)

    let sceneData: Data?
    var particleFiles: [String: Data] = [:]
    var materialFiles: [String: Data] = [:]

    if FileManager.default.fileExists(atPath: pkgFile.path) {
        guard let files = extractPKG(at: pkgFile) else { return nil }
        sceneData = files["scene.json"]
        for (name, data) in files where name.hasPrefix("particles/") {
            particleFiles[name] = data
        }
        for (name, data) in files where name.hasPrefix("materials/") && name.hasSuffix(".json") {
            materialFiles[name] = data
        }
    } else {
        let sceneFile = folderURL.appendingPathComponent("scene.json")
        sceneData = try? Data(contentsOf: sceneFile)
        if let s = decodeWEScene(from: sceneData ?? Data()) {
            for obj in s.objects ?? [] {
                if let pPath = obj.particle {
                    let pFile = folderURL.appendingPathComponent(pPath)
                    if let pData = try? Data(contentsOf: pFile) { particleFiles[pPath] = pData }
                }
            }
        }
    }

    guard let sceneData,
          let scene = decodeWEScene(from: sceneData) else { return nil }

    // Sort objects by dependencies (topological order)
    let orderedObjects = topologicalSort(scene.objects ?? [])

    var particles: [(WESceneObject, WEParticle, Bool)] = [] // (obj, particle, isAdditive)
    var waterEffects: [WEEffect] = []

    for obj in orderedObjects {
        if let pPath = obj.particle, let pData = particleFiles[pPath] {
            if let p = try? JSONDecoder().decode(WEParticle.self, from: pData) {
                // Check material blending
                var isAdditive = false
                if let matPath = p.material, let matData = materialFiles[matPath] {
                    if let matStr = String(data: matData, encoding: .utf8) {
                        isAdditive = matStr.contains("\"additive\"")
                    }
                }
                particles.append((obj, p, isAdditive))
            }
        }
        for effect in obj.effects ?? [] {
            let name = (effect.file ?? effect.name ?? "").lowercased()
            if name.contains("waterripple") || name.contains("waterflow") {
                waterEffects.append(effect)
            }
        }
    }

    // Re-extract PKG files (needed for both bg and effects)
    let allFiles: [String: Data]
    if FileManager.default.fileExists(atPath: pkgFile.path) {
        allFiles = extractPKG(at: pkgFile) ?? [:]
    } else {
        allFiles = [:]
    }

    // Decode .tex background, fall back to preview.jpg
    let bgImagePath = sceneDir.appendingPathComponent("background.png")
    var bgDecoded = false
    for obj in orderedObjects where obj.image != nil {
        let modelName = URL(fileURLWithPath: obj.image ?? "").deletingPathExtension().lastPathComponent
        if let texData = allFiles["materials/\(modelName).tex"] ?? allFiles["materials/\(modelName).texR"] {
            if let tex = decodeTex(from: texData) {
                bgDecoded = texToImageFile(tex, destination: bgImagePath)
            }
        }
    }
    if !bgDecoded {
        let previewSrc = folderURL.appendingPathComponent("preview.jpg")
        if FileManager.default.fileExists(atPath: previewSrc.path) {
            try? FileManager.default.copyItem(at: previewSrc, to: bgImagePath)
            bgDecoded = true
        }
    }

    // Extract effects: shader sources, textures, params from ALL objects
    var effectConfigs: [EffectConfig] = []
    for obj in orderedObjects {
      for effect in obj.effects ?? [] {
        guard effect.visible?.value ?? true else { continue }
        let effectFile = effect.file ?? ""
        let shaderName: String
        if effectFile.hasSuffix("/effect.json") {
            shaderName = String(effectFile.dropLast("/effect.json".count))
        } else {
            shaderName = effectFile.replacingOccurrences(of: ".json", with: "")
        }

        // Load shader sources
        let vertKey = "shaders/\(shaderName).vert"
        let fragKey = "shaders/\(shaderName).frag"
        let vertSrc = allFiles[vertKey].flatMap { String(data: $0, encoding: .utf8) }
        let fragSrc = allFiles[fragKey].flatMap { String(data: $0, encoding: .utf8) }

        // Collect params: effect-level fields first, then constantshadervalues override
        var params: [String: Float] = [:]
        if let v = effect.animationspeed { params["g_AnimationSpeed"] = Float(v) }
        if let v = effect.speed { params["g_FlowSpeed"] = Float(v) }
        if let v = effect.strength { params["g_Strength"] = Float(v); params["g_FlowAmp"] = Float(v) }
        if let v = effect.ripplestrength { params["g_Strength"] = Float(v) }
        if let v = effect.scale { params["g_Scale"] = Float(v) }
        if let v = effect.ratio { params["g_Ratio"] = Float(v) }
        if let v = effect.scrollspeed { params["g_ScrollSpeed"] = Float(v) }
        if let v = effect.scrolldirection { params["g_Direction"] = Float(v) }
        // Override from pass constantshadervalues (where WE actually stores per-effect values)
        // Map material keys to uniform names via the shader annotation mapping
        let csvKeyMap: [String: String] = [
            "animationspeed": "g_AnimationSpeed", "speed": "g_FlowSpeed",
            "strength": "g_FlowAmp", "ripplestrength": "g_Strength",
            "scale": "g_Scale", "ratio": "g_Ratio",
            "scrollspeed": "g_ScrollSpeed", "scrolldirection": "g_Direction",
            "phasescale": "g_FlowPhaseScale",
            "ripplespecularpower": "g_SpecularPower", "ripplespecularstrength": "g_SpecularStrength",
        ]
        // Set WE shader defaults for uniforms that might not appear in CSV
        let shaderDefaults: [String: Float] = [
            "g_AnimationSpeed": 0.15, "g_Strength": 0.1,
            "g_FlowSpeed": 1.0, "g_FlowAmp": 1.0, "g_FlowPhaseScale": 1.0,
            "g_Scale": 1.0, "g_Ratio": 1.0, "g_ScrollSpeed": 0.0, "g_Direction": 0.0,
            "g_SpecularPower": 1.0, "g_SpecularStrength": 1.0,
        ]
        for (k, v) in shaderDefaults { params[k] = v } // set defaults first
        for pass in effect.passes ?? [] {
            for (key, val) in pass.constantshadervalues ?? [:] {
                // Try direct mapping
                if let uniformName = csvKeyMap[key] {
                    params[uniformName] = Float(val.value)
                }
                // Also try stripping ui_editor_properties_ prefix
                let stripped = key.replacingOccurrences(of: "ui_editor_properties_", with: "")
                    .replacingOccurrences(of: "_", with: "")
                if let uniformName = csvKeyMap[stripped] {
                    params[uniformName] = Float(val.value)
                }
            }
        }

        // Extract textures from per-pass texture array in scene.json
        // Format: [null, "masks/waterflow_mask_xxx", "effects/waterflowphase"]
        // Index 0 = framebuffer (null), 1 = mask/flow map, 2 = normal/phase map
        var maskPath: String?
        var extraPaths: [String] = []

        // Use texture paths from the first pass (most effects have one pass)
        let passTextures = (effect.passes ?? []).first?.textures ?? []
        for (texIdx, texRef) in passTextures.enumerated() {
            guard let ref = texRef, texIdx > 0 else { continue } // skip index 0 (framebuffer)

            // Try to find the texture in PKG with .tex suffix
            let texKey = ref.hasSuffix(".tex") ? ref : "\(ref).tex"
            // Also try materials/ prefix if not already present
            let candidates = [texKey, "materials/\(texKey)"]
            var decoded = false
            for candidate in candidates {
                if let texData = allFiles[candidate], let tex = decodeTex(from: texData) {
                    let saveName = "tex_\(effectConfigs.count)_\(texIdx).png"
                    let savePath = sceneDir.appendingPathComponent(saveName)
                    if texToImageFile(tex, destination: savePath) {
                        if texIdx == 1 { maskPath = savePath.path }
                        else { extraPaths.append(savePath.path) }
                        decoded = true
                        break
                    }
                }
            }
            if !decoded {
                fputs("[VW-CFG] Missing texture: \(ref) for effect \(shaderName)\n", stderr)
            }
        }

        // Fallback: pattern match from PKG if pass textures were empty
        if passTextures.isEmpty || passTextures.allSatisfy({ $0 == nil }) {
            let baseName = URL(string: shaderName)?.lastPathComponent ?? shaderName
            for key in allFiles.keys.sorted() where key.contains("masks/\(baseName)_mask_") && key.hasSuffix(".tex") {
                if let texData = allFiles[key], let tex = decodeTex(from: texData) {
                    let saveName = "tex_\(effectConfigs.count)_mask.png"
                    let savePath = sceneDir.appendingPathComponent(saveName)
                    if texToImageFile(tex, destination: savePath) {
                        maskPath = maskPath ?? savePath.path
                    }
                }
            }
            for key in allFiles.keys.sorted() where key.hasPrefix("materials/effects/\(baseName)") && key.hasSuffix(".tex") {
                if let texData = allFiles[key], let tex = decodeTex(from: texData) {
                    let safeName = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ".tex", with: ".png")
                    let savePath = sceneDir.appendingPathComponent(safeName)
                    if texToImageFile(tex, destination: savePath) {
                        extraPaths.append(savePath.path)
                    }
                }
            }
        }

        fputs("[VW-CFG] Effect \(shaderName): mask=\(maskPath != nil), extras=\(extraPaths.count), params=\(params.filter { $0.key.hasPrefix("g_") }.mapValues { String(format: "%.3f", $0) })\n", stderr)
        effectConfigs.append(EffectConfig(
            type: shaderName, params: params,
            maskTexturePath: maskPath, extraTexturePaths: extraPaths,
            vertexShaderSource: vertSrc, fragmentShaderSource: fragSrc
        ))
      }
    }

    let sceneW = scene.general?.orthogonalprojection?.width ?? 1920
    let sceneH = scene.general?.orthogonalprojection?.height ?? 1080

    // Build per-layer configs
    var layerConfigs: [LayerConfig] = []
    var effectIdx = 0
    for obj in orderedObjects where obj.image != nil {
        let o = parseVec(obj.origin)
        let s = parseVec(obj.size)
        let sc = parseVec(obj.scale)
        let pd = parseVec(obj.parallaxDepth)

        // Find this layer's texture path (already decoded above)
        let texPath = bgDecoded ? bgImagePath.path : nil

        // Match effects by index from effectConfigs (built in same order)
        var layerEffects: [EffectConfig] = []
        for _ in obj.effects ?? [] {
            if effectIdx < effectConfigs.count {
                layerEffects.append(effectConfigs[effectIdx])
                effectIdx += 1
            }
        }

        layerConfigs.append(LayerConfig(
            id: obj.id ?? 0, texturePath: texPath,
            originX: Float(o.count > 0 ? o[0] : 0), originY: Float(o.count > 1 ? o[1] : 0),
            sizeW: Float(s.count > 0 ? s[0] : Double(sceneW)), sizeH: Float(s.count > 1 ? s[1] : Double(sceneH)),
            scaleX: Float(sc.count > 0 ? sc[0] : 1), scaleY: Float(sc.count > 1 ? sc[1] : 1),
            alpha: 1.0,
            parallaxX: Float(pd.count > 0 ? pd[0] : 1), parallaxY: Float(pd.count > 1 ? pd[1] : 1),
            colorBlendMode: 0,
            visible: obj.visible?.value ?? true,
            effects: layerEffects
        ))
    }

    // Find sound file
    var soundPath: String?
    for key in allFiles.keys where key.hasSuffix(".mp3") || key.hasSuffix(".ogg") || key.hasSuffix(".flac") || key.hasSuffix(".wav") {
        let savePath = sceneDir.appendingPathComponent(URL(fileURLWithPath: key).lastPathComponent)
        try? allFiles[key]?.write(to: savePath)
        soundPath = savePath.path
    }
    // Also check folder directly
    if soundPath == nil {
        for ext in ["mp3", "ogg", "flac", "wav"] {
            let files = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            if let f = files?.first(where: { $0.pathExtension.lowercased() == ext }) {
                soundPath = f.path
                break
            }
        }
    }

    let sceneMetadata = SceneMetadata(
        sceneWidth: sceneW, sceneHeight: sceneH,
        backgroundPath: bgDecoded ? bgImagePath.path : nil,
        parallax: scene.general?.cameraparallax ?? false,
        parallaxAmount: scene.general?.cameraparallaxamount ?? 0.5,
        parallaxDelay: scene.general?.cameraparallaxdelay ?? 0.1,
        particles: particles.map { buildParticleConfig(obj: $0.0, particle: $0.1, isAdditive: $0.2,
                                                        sceneW: Float(sceneW), sceneH: Float(sceneH)) },
        effects: effectConfigs,
        layers: layerConfigs.isEmpty ? nil : layerConfigs,
        bloomEnabled: scene.general?.bloom,
        bloomStrength: scene.general?.bloomstrength,
        bloomThreshold: scene.general?.bloomthreshold,
        soundPath: soundPath
    )
    let metadataFile = sceneDir.appendingPathComponent("metadata.json")
    if let encoded = try? JSONEncoder().encode(sceneMetadata) {
        try? encoded.write(to: metadataFile)
    }

    return WEParseResult(
        source: WallpaperSource(type: .scene, path: sceneDir.path, title: title),
        title: title, propertyJS: nil
    )
}

// MARK: - Scene HTML Generator

/// Decode WEScene, sanitizing problematic float literals that JSONDecoder rejects
func decodeWEScene(from data: Data) -> WEScene? {
    // Sanitize: some WE scene.json files have float values with too many digits
    // that Swift's JSONDecoder rejects (e.g. 0.23000000417232513)
    guard let jsonStr = String(data: data, encoding: .utf8) else { return nil }
    // Replace problematic floats by scanning character-by-character
    var result = ""
    result.reserveCapacity(jsonStr.count)
    var i = jsonStr.startIndex
    while i < jsonStr.endIndex {
        let ch = jsonStr[i]
        // Detect number start after : or , or [ or whitespace
        if ch == "-" || ch.isNumber {
            var numEnd = i
            var hasDot = false
            var decDigits = 0
            var j = i
            while j < jsonStr.endIndex {
                let c = jsonStr[j]
                if c == "." { hasDot = true; j = jsonStr.index(after: j); continue }
                if c == "-" || c.isNumber {
                    if hasDot { decDigits += 1 }
                    j = jsonStr.index(after: j)
                    continue
                }
                break
            }
            numEnd = j
            let numStr = String(jsonStr[i..<numEnd])
            if hasDot && decDigits > 8, let d = Double(numStr) {
                result += String(format: "%.6f", d)
            } else {
                result += numStr
            }
            i = numEnd
        } else {
            result.append(ch)
            i = jsonStr.index(after: i)
        }
    }
    guard let cleaned = result.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(WEScene.self, from: cleaned)
}

/// Topological sort of scene objects by dependency IDs
private func topologicalSort(_ objects: [WESceneObject]) -> [WESceneObject] {
    let idMap = Dictionary(uniqueKeysWithValues: objects.compactMap { obj in
        obj.id.map { ($0, obj) }
    })
    var visited = Set<Int>()
    var result: [WESceneObject] = []

    func visit(_ obj: WESceneObject) {
        guard let id = obj.id, !visited.contains(id) else { return }
        visited.insert(id)
        for depId in obj.dependencies ?? [] {
            if let dep = idMap[depId] { visit(dep) }
        }
        result.append(obj)
    }

    for obj in objects { visit(obj) }
    return result
}

private func parseVec(_ s: String?) -> [Double] {
    (s ?? "0 0 0").split(separator: " ").map { Double($0) ?? 0 }
}

