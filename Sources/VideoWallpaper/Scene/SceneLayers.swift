#if ENABLE_SCENE
import AppKit
import MetalKit

// MARK: - Layer model

struct ImageLayer {
    let texture: MTLTexture
    var origin: SIMD2<Float>      // center position in scene coords
    var size: SIMD2<Float>        // size in scene coords
    var scale: SIMD3<Float> = SIMD3(1, 1, 1)
    var alpha: Float = 1.0
    var parallaxDepth: SIMD2<Float> = SIMD2(1, 1)
    var colorBlendMode: Int = 0   // 0=normal, 1=additive, 2=multiply
    var visible: Bool = true
    var effects: [LayerEffect] = []
    var fboA: MTLTexture?
    var fboB: MTLTexture?
}

struct LayerEffect {
    let type: String
    let params: [String: Float]
    let maskKey: String?
    let normalOrPhaseKey: String?
}

// MARK: - GPU uniform structs

struct QuadUniforms {
    var uMin: Float, uMax: Float, vMin: Float, vMax: Float, alpha: Float
}

struct EffectUniforms {
    var time: Float, strength: Float, speed: Float, scale: Float, ratio: Float
    var scrollSpeed: Float, scrollDirection: Float
    var texWidth: Float, texHeight: Float
}

// MARK: - SceneEngine: texture loading & effect compilation

extension SceneEngine {
    func makeTexture(from cgImage: CGImage) -> MTLTexture? {
        let w = cgImage.width, h = cgImage.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let ctx = CGContext(data: &pixels, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    func makeFBO(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        return device.makeTexture(descriptor: desc)
    }

    func safeTexture(_ key: String?) -> MTLTexture {
        if let k = key, let t = effectTextures[k] { return t }
        return fallbackTexture!
    }

    func compileEffect(name: String, vertexSource: String?, fragmentSource: String?,
                        includes: [String: String] = [:]) {
        guard effectPipelines[name] == nil, let fragSrc = fragmentSource else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        let result = GLSLTranslator.translateFragment(source: fragSrc, name: safeName, includes: includes)
        // Always use hardcoded effectVertex — vertex UV computations are moved to fragment
        let baseLib = try? device.makeLibrary(source: SceneEngine.metalShaderSource, options: nil)
        do {
            let lib = try device.makeLibrary(source: result.msl, options: nil)
            let vertFn = baseLib?.makeFunction(name: "effectVertex")
            let fragFn = lib.makeFunction(name: "frag_\(safeName)")
            guard let vf = vertFn, let ff = fragFn else {
                SceneLog.shader.error("\(name, privacy: .public): missing functions")
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vf; desc.fragmentFunction = ff
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            effectPipelines[name] = try device.makeRenderPipelineState(descriptor: desc)
            effectUniformLayouts[name] = result.uniformNames
            SceneLog.shader.debug("compiled \(name, privacy: .public)")
        } catch {
            SceneLog.shader.error("\(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - SceneEngine: bundle configuration

extension SceneEngine {
    /// Populate the engine from a parsed SceneBundle in one shot. Callers should
    /// not poke at `imageLayers`, `particleSystems`, or `effectTextures` directly.
    func configure(with bundle: SceneBundle) {
        sceneWidth = Float(bundle.sceneWidth)
        sceneHeight = Float(bundle.sceneHeight)
        parallaxEnabled = bundle.parallax
        parallaxAmount = Float(bundle.parallaxAmount)
        parallaxDelay = Float(bundle.parallaxDelay)
        bloomEnabled = bundle.bloomEnabled
        bloomStrength = Float(bundle.bloomStrength)
        bloomThreshold = Float(bundle.bloomThreshold)

        for lb in bundle.layers { addLayer(lb) }
        for pc in bundle.particles { addParticleSystem(pc) }
        if let soundURL = bundle.soundURL { playSound(at: soundURL) }
    }

    /// Compile shaders, upload mask/extra textures, and append one ImageLayer.
    /// Skips silently if the layer has no decoded texture.
    func addLayer(_ lb: SceneLayerBundle) {
        guard let cgImage = lb.texture,
              let texture = makeTexture(from: cgImage) else { return }

        var effects: [LayerEffect] = []
        for (effectIdx, eb) in lb.effects.enumerated() {
            if let fragSrc = eb.fragmentShaderSource {
                compileEffect(name: eb.type,
                              vertexSource: eb.vertexShaderSource,
                              fragmentSource: fragSrc,
                              includes: ["common.h": weCommonH])
            }
            var maskKey: String?
            if let maskImg = eb.maskImage {
                let key = "mask_\(lb.id)_\(effectIdx)"
                effectTextures[key] = makeTexture(from: maskImg)
                maskKey = key
            }
            var normalKey: String?
            for (ti, extraImg) in eb.extraImages.enumerated() {
                let key = "extra_\(lb.id)_\(effectIdx)_\(ti)"
                effectTextures[key] = makeTexture(from: extraImg)
                if normalKey == nil { normalKey = key }
            }
            effects.append(LayerEffect(type: eb.type, params: eb.params,
                                        maskKey: maskKey, normalOrPhaseKey: normalKey))
        }

        imageLayers.append(ImageLayer(
            texture: texture,
            origin: SIMD2(lb.originX, lb.originY),
            size: SIMD2(lb.sizeW, lb.sizeH),
            scale: SIMD3(lb.scaleX, lb.scaleY, 1),
            alpha: lb.alpha,
            parallaxDepth: SIMD2(lb.parallaxX, lb.parallaxY),
            colorBlendMode: lb.colorBlendMode,
            visible: lb.visible,
            effects: effects
        ))
    }

    /// Wrap a ParticleConfig into a ParticleSystem and append it.
    func addParticleSystem(_ pc: ParticleConfig) {
        particleSystems.append(ParticleSystem(config: ParticleSystemConfig(
            ox: pc.ox, oy: pc.oy,
            emitterOffsetX: pc.emitterOffsetX, emitterOffsetY: pc.emitterOffsetY,
            spawnW: pc.spawnW, spawnH: pc.spawnH,
            rate: pc.rate, maxcount: pc.maxcount,
            sizeMin: pc.sizeMin, sizeMax: pc.sizeMax,
            velXMin: pc.velXMin, velXMax: pc.velXMax,
            velYMin: pc.velYMin, velYMax: pc.velYMax,
            lifetimeMin: pc.lifetimeMin, lifetimeMax: pc.lifetimeMax,
            color: SIMD3(pc.colorR, pc.colorG, pc.colorB),
            alphaMin: pc.alphaMin, alphaMax: pc.alphaMax,
            fadeIn: pc.fadeIn, fadeOut: pc.fadeOut,
            oscPosAmpMin: pc.oscPosAmpMin, oscPosAmpMax: pc.oscPosAmpMax,
            oscPosFreqMin: pc.oscPosFreqMin, oscPosFreqMax: pc.oscPosFreqMax,
            oscAlphaFreqMin: pc.oscAlphaFreqMin, oscAlphaFreqMax: pc.oscAlphaFreqMax,
            oscAlphaScaleMin: pc.oscAlphaScaleMin, oscAlphaScaleMax: pc.oscAlphaScaleMax,
            sizeStart: pc.sizeStart, sizeEnd: pc.sizeEnd,
            cursorRepel: pc.cursorRepel, cursorThreshold: pc.cursorThreshold,
            drag: pc.drag, starttime: pc.starttime,
            soft: pc.soft, additive: pc.additive,
            turbulenceScale: pc.turbulenceScale,
            turbulenceSpeed: pc.turbulenceSpeed,
            turbulenceStrength: pc.turbulenceStrength,
            vortexStrength: pc.vortexStrength, vortexSpeed: pc.vortexSpeed,
            angVelMin: pc.angVelMin, angVelMax: pc.angVelMax,
            rendererType: pc.rendererType
        )))
    }
}

// MARK: - SceneEngine: per-layer rendering

extension SceneEngine {
    /// Render one ImageLayer into the currently-bound scene FBO via `encoder`.
    func renderLayer(_ idx: Int, encoder: MTLRenderCommandEncoder) {
        let layer = imageLayers[idx]

        // Parallax offset per layer
        var px: Float = 0, py: Float = 0
        if parallaxEnabled && (layer.parallaxDepth.x != 1 || layer.parallaxDepth.y != 1) {
            px = (smoothX - 0.5) * parallaxAmount * 0.02 * (1 - layer.parallaxDepth.x)
            py = (smoothY - 0.5) * parallaxAmount * 0.02 * (1 - layer.parallaxDepth.y)
        }

        // Blend pipeline for layers with alpha or non-first layers
        let pipeline = (idx == 0 && layer.alpha >= 1.0) ? quadPipeline : quadBlendPipeline
        encoder.setRenderPipelineState(pipeline)

        var uniforms = QuadUniforms(
            uMin: 0 + px, uMax: 1 + px,
            vMin: 0 + py, vMax: 1 + py,
            alpha: layer.alpha
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.size, index: 0)
        encoder.setFragmentTexture(layer.texture, index: 0)
        encoder.setFragmentSamplerState(clampSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Apply this layer's effect chain via FBO ping-pong, then composite the result
    /// back into the scene FBO.
    func applyLayerEffects(layerIndex: Int, commandBuffer: MTLCommandBuffer) {
        let layer = imageLayers[layerIndex]
        guard !layer.effects.isEmpty else { return }

        // Ensure per-layer FBOs match texture size
        let tw = layer.texture.width, th = layer.texture.height
        if imageLayers[layerIndex].fboA == nil || imageLayers[layerIndex].fboA!.width != tw {
            imageLayers[layerIndex].fboA = makeFBO(width: tw, height: th)
            imageLayers[layerIndex].fboB = makeFBO(width: tw, height: th)
        }
        guard let fA = imageLayers[layerIndex].fboA,
              let fB = imageLayers[layerIndex].fboB else { return }

        // Ping-pong: start from the raw layer texture; alternate fA/fB as output
        var input: MTLTexture = layer.texture
        var output: MTLTexture = fA
        for effect in layer.effects {
            guard let pipeline = effectPipelines[effect.type] else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.setRenderPipelineState(pipeline)

            // Standardized uniform buffer matching all translated shader structs
            let t1 = safeTexture(effect.maskKey)
            let t2 = safeTexture(effect.normalOrPhaseKey)
            var uniformData: [Float] = [
                totalTime,                                              // g_Time
                0,                                                       // g_Daytime
                smoothX, smoothY,                                        // g_PointerPosition
                Float(input.width), Float(input.height),                // g_Texture0Resolution
                Float(input.width), Float(input.height),
                Float(t1.width), Float(t1.height),                      // g_Texture1Resolution
                Float(t1.width), Float(t1.height),
                Float(t2.width), Float(t2.height),                      // g_Texture2Resolution
                Float(t2.width), Float(t2.height),
                effect.params["g_AnimationSpeed"] ?? 0.15,
                effect.params["g_Strength"] ?? 0.1,
                effect.params["g_Scale"] ?? 1.0,
                effect.params["g_Ratio"] ?? 1.0,
                effect.params["g_ScrollSpeed"] ?? 0.0,
                effect.params["g_Direction"] ?? 0.0,
                effect.params["g_FlowSpeed"] ?? 1.0,
                effect.params["g_FlowAmp"] ?? 1.0,
                effect.params["g_FlowPhaseScale"] ?? 1.0,
                effect.params["g_SpecularPower"] ?? 1.0,
                effect.params["g_SpecularStrength"] ?? 1.0,
                0, 0, 0,                                                 // g_SpecularColor (float3, padded)
            ]
            enc.setFragmentBytes(&uniformData, length: uniformData.count * 4, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentTexture(safeTexture(effect.maskKey), index: 1)
            enc.setFragmentTexture(safeTexture(effect.normalOrPhaseKey), index: 2)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            swap(&input, &output)
        }
        _ = fB // referenced only to suppress unused-binding warning; kept for symmetry with fA

        // Composite the effected texture back into the scene FBO
        guard let sceneTex = sceneFBO else { return }
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = sceneTex
        finalPass.colorAttachments[0].loadAction = .load // preserve other layers
        finalPass.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: finalPass) {
            enc.setRenderPipelineState(quadPipeline)
            var fullUV = QuadUniforms(uMin: 0, uMax: 1, vMin: 0, vMax: 1, alpha: 1)
            enc.setVertexBytes(&fullUV, length: MemoryLayout<QuadUniforms>.size, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentSamplerState(clampSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
    }
}
#endif
