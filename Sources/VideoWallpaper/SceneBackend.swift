#if ENABLE_SCENE
import AppKit
import MetalKit

@MainActor
func setupSceneContent(window: NSWindow, screen: NSScreen, sceneDir: URL) -> SceneEngine? {
    let metadataFile = sceneDir.appendingPathComponent("metadata.json")
    guard let data = try? Data(contentsOf: metadataFile),
          let metadata = try? JSONDecoder().decode(SceneMetadata.self, from: data) else { return nil }

    let mtkView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size))
    mtkView.layer?.isOpaque = true
    mtkView.preferredFramesPerSecond = 60

    guard let engine = SceneEngine(mtkView: mtkView) else { return nil }

    engine.sceneWidth = Float(metadata.sceneWidth)
    engine.sceneHeight = Float(metadata.sceneHeight)
    engine.parallaxEnabled = metadata.parallax
    engine.parallaxAmount = Float(metadata.parallaxAmount)
    engine.parallaxDelay = Float(metadata.parallaxDelay)
    engine.bloomEnabled = metadata.bloomEnabled ?? false
    engine.bloomStrength = Float(metadata.bloomStrength ?? 1.0)
    engine.bloomThreshold = Float(metadata.bloomThreshold ?? 0.5)

    // Load image layers
    for layerMeta in metadata.layers ?? [] {
        guard let texPath = layerMeta.texturePath,
              let nsImage = NSImage(contentsOfFile: texPath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let texture = engine.makeTexture(from: cgImage) else { continue }

        var effects: [LayerEffect] = []
        for (idx, ec) in layerMeta.effects.enumerated() {
            if let fragSrc = ec.fragmentShaderSource {
                engine.compileEffect(name: ec.type, vertexSource: ec.vertexShaderSource,
                                      fragmentSource: fragSrc, includes: ["common.h": weCommonH])
            }
            var maskKey: String?
            if let maskPath = ec.maskTexturePath,
               let img = NSImage(contentsOfFile: maskPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let key = "mask_\(layerMeta.id)_\(idx)"
                engine.effectTextures[key] = engine.makeTexture(from: img)
                maskKey = key
            }
            var normalKey: String?
            for (ti, tp) in ec.extraTexturePaths.enumerated() {
                if let img = NSImage(contentsOfFile: tp)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let key = "extra_\(layerMeta.id)_\(idx)_\(ti)"
                    engine.effectTextures[key] = engine.makeTexture(from: img)
                    if normalKey == nil { normalKey = key }
                }
            }
            effects.append(LayerEffect(type: ec.type, params: ec.params,
                                        maskKey: maskKey, normalOrPhaseKey: normalKey))
        }

        let layer = ImageLayer(
            texture: texture,
            origin: SIMD2(layerMeta.originX, layerMeta.originY),
            size: SIMD2(layerMeta.sizeW, layerMeta.sizeH),
            scale: SIMD3(layerMeta.scaleX, layerMeta.scaleY, 1),
            alpha: layerMeta.alpha,
            parallaxDepth: SIMD2(layerMeta.parallaxX, layerMeta.parallaxY),
            colorBlendMode: layerMeta.colorBlendMode,
            visible: layerMeta.visible,
            effects: effects
        )
        engine.imageLayers.append(layer)
    }

    // Fallback: no layers but backgroundPath → create single layer
    if engine.imageLayers.isEmpty, let bgPath = metadata.backgroundPath,
       let nsImage = NSImage(contentsOfFile: bgPath),
       let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
       let texture = engine.makeTexture(from: cgImage) {
        let sw = Float(metadata.sceneWidth), sh = Float(metadata.sceneHeight)
        var layer = ImageLayer(texture: texture, origin: SIMD2(sw/2, sh/2), size: SIMD2(sw, sh))
        for (idx, ec) in (metadata.effects).enumerated() {
            if let fragSrc = ec.fragmentShaderSource {
                engine.compileEffect(name: ec.type, vertexSource: ec.vertexShaderSource,
                                      fragmentSource: fragSrc, includes: ["common.h": weCommonH])
            }
            var maskKey: String?
            if let mp = ec.maskTexturePath, let img = NSImage(contentsOfFile: mp)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let key = "mask_\(idx)"
                engine.effectTextures[key] = engine.makeTexture(from: img)
                maskKey = key
            }
            var nk: String?
            for (ti, tp) in ec.extraTexturePaths.enumerated() {
                if let img = NSImage(contentsOfFile: tp)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let key = "extra_\(idx)_\(ti)"
                    engine.effectTextures[key] = engine.makeTexture(from: img)
                    if nk == nil { nk = key }
                }
            }
            layer.effects.append(LayerEffect(type: ec.type, params: ec.params,
                                              maskKey: maskKey, normalOrPhaseKey: nk))
        }
        engine.imageLayers.append(layer)
    }

    // Particle systems
    for pc in metadata.particles {
        engine.particleSystems.append(ParticleSystem(config: ParticleSystemConfig(
            ox: pc.ox, oy: pc.oy, emitterOffsetX: pc.emitterOffsetX, emitterOffsetY: pc.emitterOffsetY,
            spawnW: pc.spawnW, spawnH: pc.spawnH, rate: pc.rate, maxcount: pc.maxcount,
            sizeMin: pc.sizeMin, sizeMax: pc.sizeMax,
            velXMin: pc.velXMin, velXMax: pc.velXMax, velYMin: pc.velYMin, velYMax: pc.velYMax,
            lifetimeMin: pc.lifetimeMin, lifetimeMax: pc.lifetimeMax,
            color: SIMD3(pc.colorR, pc.colorG, pc.colorB),
            alphaMin: pc.alphaMin, alphaMax: pc.alphaMax, fadeIn: pc.fadeIn, fadeOut: pc.fadeOut,
            oscPosAmpMin: pc.oscPosAmpMin, oscPosAmpMax: pc.oscPosAmpMax,
            oscPosFreqMin: pc.oscPosFreqMin, oscPosFreqMax: pc.oscPosFreqMax,
            oscAlphaFreqMin: pc.oscAlphaFreqMin, oscAlphaFreqMax: pc.oscAlphaFreqMax,
            oscAlphaScaleMin: pc.oscAlphaScaleMin, oscAlphaScaleMax: pc.oscAlphaScaleMax,
            sizeStart: pc.sizeStart, sizeEnd: pc.sizeEnd,
            cursorRepel: pc.cursorRepel, cursorThreshold: pc.cursorThreshold,
            drag: pc.drag, starttime: pc.starttime, soft: pc.soft, additive: pc.additive,
            turbulenceScale: pc.turbulenceScale, turbulenceSpeed: pc.turbulenceSpeed,
            turbulenceStrength: pc.turbulenceStrength,
            vortexStrength: pc.vortexStrength, vortexSpeed: pc.vortexSpeed,
            angVelMin: pc.angVelMin, angVelMax: pc.angVelMax,
            rendererType: pc.rendererType
        )))
    }

    if let soundPath = metadata.soundPath {
        engine.playSound(at: URL(fileURLWithPath: soundPath))
    }

    window.contentView = mtkView
    return engine
}
#endif
