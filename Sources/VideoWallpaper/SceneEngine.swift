#if ENABLE_SCENE
import AppKit
import MetalKit
import AVFoundation

// MARK: - Image Layer

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

// MARK: - Scene Engine

@MainActor
final class SceneEngine: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let quadPipeline: MTLRenderPipelineState
    private let quadBlendPipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let clampSampler: MTLSamplerState

    var sceneWidth: Float = 1920
    var sceneHeight: Float = 1080
    private var viewWidth: Float = 1920
    private var viewHeight: Float = 1080

    // Scene FBO (all layers composite here)
    private var sceneFBO: MTLTexture?

    // Mouse
    private var mouseX: Float = 0.5
    private var mouseY: Float = 0.5
    private var smoothX: Float = 0.5
    private var smoothY: Float = 0.5
    var parallaxEnabled = false
    var parallaxAmount: Float = 0.5
    var parallaxDelay: Float = 0.1

    // Layers & particles
    var imageLayers: [ImageLayer] = []
    var particleSystems: [ParticleSystem] = []
    private var lastFrameTime: CFTimeInterval = 0
    var totalTime: Float = 0

    // Effects
    var effectPipelines: [String: MTLRenderPipelineState] = [:]
    var effectTextures: [String: MTLTexture] = [:]

    // Bloom
    var bloomEnabled = false
    var bloomStrength: Float = 1.0
    var bloomThreshold: Float = 0.5
    private var bloomFBO4: MTLTexture?  // 1/4 res
    private var bloomFBO8: MTLTexture?  // 1/8 res
    private var bloomPipeline: MTLRenderPipelineState?

    // Audio
    var audioPlayer: AVAudioPlayer?

    // MARK: - Init

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        self.device = device
        self.commandQueue = queue
        mtkView.device = device
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        mtkView.colorPixelFormat = .bgra8Unorm

        let shaderSrc = SceneEngine.metalShaderSource
        guard let library = try? device.makeLibrary(source: shaderSrc, options: nil) else { return nil }

        // Quad pipeline (opaque)
        let qDesc = MTLRenderPipelineDescriptor()
        qDesc.vertexFunction = library.makeFunction(name: "quadVertex")
        qDesc.fragmentFunction = library.makeFunction(name: "quadFragment")
        qDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let qPipe = try? device.makeRenderPipelineState(descriptor: qDesc) else { return nil }
        self.quadPipeline = qPipe

        // Quad pipeline (alpha blend for compositing layers)
        let qbDesc = MTLRenderPipelineDescriptor()
        qbDesc.vertexFunction = library.makeFunction(name: "quadVertex")
        qbDesc.fragmentFunction = library.makeFunction(name: "quadFragment")
        qbDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        qbDesc.colorAttachments[0].isBlendingEnabled = true
        qbDesc.colorAttachments[0].rgbBlendOperation = .add
        qbDesc.colorAttachments[0].alphaBlendOperation = .add
        qbDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        qbDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        qbDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        qbDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let qbPipe = try? device.makeRenderPipelineState(descriptor: qbDesc) else { return nil }
        self.quadBlendPipeline = qbPipe

        // Particle pipeline
        let ptDesc = MTLRenderPipelineDescriptor()
        ptDesc.vertexFunction = library.makeFunction(name: "particleVertex")
        ptDesc.fragmentFunction = library.makeFunction(name: "particleFragment")
        ptDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        ptDesc.colorAttachments[0].isBlendingEnabled = true
        ptDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        ptDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        ptDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        ptDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let ptPipe = try? device.makeRenderPipelineState(descriptor: ptDesc) else { return nil }
        self.particlePipeline = ptPipe

        // Samplers
        let sDesc = MTLSamplerDescriptor()
        sDesc.minFilter = .linear; sDesc.magFilter = .linear
        sDesc.sAddressMode = .repeat; sDesc.tAddressMode = .repeat
        guard let samp = device.makeSamplerState(descriptor: sDesc) else { return nil }
        self.sampler = samp

        let cDesc = MTLSamplerDescriptor()
        cDesc.minFilter = .linear; cDesc.magFilter = .linear
        cDesc.sAddressMode = .clampToEdge; cDesc.tAddressMode = .clampToEdge
        guard let csamp = device.makeSamplerState(descriptor: cDesc) else { return nil }
        self.clampSampler = csamp

        // No hardcoded effect pipelines — all effects use GLSL→MSL translated shaders from the PKG

        // Bloom pipeline
        if let bloomFrag = library.makeFunction(name: "bloomFragment"),
           let bloomVert = library.makeFunction(name: "effectVertex") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = bloomVert
            desc.fragmentFunction = bloomFrag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .one
            bloomPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        super.init()
        mtkView.delegate = self
    }

    // MARK: - Texture Loading

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

    private lazy var fallbackTexture: MTLTexture? = {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var white: [UInt8] = [255, 255, 255, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        return tex
    }()

    func safeTexture(_ key: String?) -> MTLTexture {
        if let k = key, let t = effectTextures[k] { return t }
        return fallbackTexture!
    }

    // MARK: - Dynamic Shader Compilation

    /// Stores the uniform layout for each compiled effect shader
    var effectUniformLayouts: [String: [String]] = [:] // effect name → ordered uniform names

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
                fputs("[VW-SHADER] \(name): missing functions\n", stderr)
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vf; desc.fragmentFunction = ff
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            effectPipelines[name] = try device.makeRenderPipelineState(descriptor: desc)
            effectUniformLayouts[name] = result.uniformNames
            fputs("[VW-SHADER] Compiled \(name)\n", stderr)
        } catch {
            fputs("[VW-SHADER] \(name): \(error)\n", stderr)
        }
    }

    // MARK: - Mouse

    func updateMouse(_ x: Float, _ y: Float) { mouseX = x; mouseY = y }

    // MARK: - Audio

    func playSound(at url: URL) {
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.numberOfLoops = -1 // loop forever
        audioPlayer?.volume = 0.5
        audioPlayer?.play()
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            viewWidth = Float(size.width); viewHeight = Float(size.height)
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    // MARK: - Render

    private func drawFrame(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime > 0 ? Float(now - lastFrameTime) : 1.0 / 60.0
        lastFrameTime = now
        totalTime += dt

        // Smooth mouse
        let lf = min(1.0, dt / max(0.01, parallaxDelay))
        smoothX += (mouseX - smoothX) * lf
        smoothY += (mouseY - smoothY) * lf

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Ensure scene FBO
        let sw = Int(sceneWidth), sh = Int(sceneHeight)
        if sceneFBO == nil || sceneFBO!.width != sw || sceneFBO!.height != sh {
            sceneFBO = makeFBO(width: sw, height: sh)
        }
        guard let sceneTex = sceneFBO else { return }

        // --- Render all layers into scene FBO ---
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneTex
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            for i in 0..<imageLayers.count {
                guard imageLayers[i].visible else { continue }
                renderLayer(i, encoder: enc)
            }

            // Particles
            enc.setRenderPipelineState(particlePipeline)
            for i in 0..<particleSystems.count {
                particleSystems[i].update(dt: dt, mouseX: smoothX, mouseY: smoothY)
                particleSystems[i].render(encoder: enc, viewW: sceneWidth, viewH: sceneHeight)
            }
            enc.endEncoding()
        }

        // --- Apply effects per layer that need FBO ping-pong ---
        for i in 0..<imageLayers.count {
            guard !imageLayers[i].effects.isEmpty else { continue }
            applyLayerEffects(layerIndex: i, commandBuffer: commandBuffer)
        }

        // --- Blit scene to screen with ZoomFill ---
        let viewAspect = viewWidth / viewHeight
        let sceneAspect = sceneWidth / sceneHeight
        var uMin: Float = 0, uMax: Float = 1, vMin: Float = 0, vMax: Float = 1
        if viewAspect > sceneAspect {
            let vis = sceneAspect / viewAspect
            vMin = (1 - vis) / 2; vMax = 1 - vMin
        } else {
            let vis = viewAspect / sceneAspect
            uMin = (1 - vis) / 2; uMax = 1 - uMin
        }
        if parallaxEnabled {
            let px = (smoothX - 0.5) * parallaxAmount * 0.02
            let py = (smoothY - 0.5) * parallaxAmount * 0.02
            uMin += px; uMax += px; vMin += py; vMax += py
        }

        guard let screenPass = view.currentRenderPassDescriptor,
              let enc = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) else { return }
        enc.setRenderPipelineState(quadPipeline)
        var uniforms = QuadUniforms(uMin: uMin, uMax: uMax, vMin: vMin, vMax: vMax, alpha: 1)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.size, index: 0)
        enc.setFragmentTexture(sceneTex, index: 0)
        enc.setFragmentSamplerState(clampSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderLayer(_ idx: Int, encoder: MTLRenderCommandEncoder) {
        let layer = imageLayers[idx]
        // Compute UV rect for this layer in scene space
        let ox = layer.origin.x / sceneWidth
        let oy = layer.origin.y / sceneHeight
        let hw = (layer.size.x * layer.scale.x) / sceneWidth / 2
        let hh = (layer.size.y * layer.scale.y) / sceneHeight / 2

        // Parallax offset per layer
        var px: Float = 0, py: Float = 0
        if parallaxEnabled && (layer.parallaxDepth.x != 1 || layer.parallaxDepth.y != 1) {
            px = (smoothX - 0.5) * parallaxAmount * 0.02 * (1 - layer.parallaxDepth.x)
            py = (smoothY - 0.5) * parallaxAmount * 0.02 * (1 - layer.parallaxDepth.y)
        }

        // Use blend pipeline for layers with alpha or non-first layers
        let pipeline = (idx == 0 && layer.alpha >= 1.0) ? quadPipeline : quadBlendPipeline
        encoder.setRenderPipelineState(pipeline)

        // If layer covers full scene (common case), use simple full-quad
        let fullScreen = layer.size.x >= sceneWidth && layer.size.y >= sceneHeight
        var uniforms: QuadUniforms
        if fullScreen {
            uniforms = QuadUniforms(uMin: 0 + px, uMax: 1 + px, vMin: 0 + py, vMax: 1 + py, alpha: layer.alpha)
        } else {
            // Positioned layer — compute NDC quad coords
            // For now, render as full quad with UV mapping (simplified)
            uniforms = QuadUniforms(uMin: 0 + px, uMax: 1 + px, vMin: 0 + py, vMax: 1 + py, alpha: layer.alpha)
        }

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.size, index: 0)
        encoder.setFragmentTexture(layer.texture, index: 0)
        encoder.setFragmentSamplerState(clampSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func applyLayerEffects(layerIndex: Int, commandBuffer: MTLCommandBuffer) {
        let layer = imageLayers[layerIndex]
        guard !layer.effects.isEmpty else { return }

        // Ensure per-layer FBOs
        let tw = layer.texture.width, th = layer.texture.height
        if imageLayers[layerIndex].fboA == nil || imageLayers[layerIndex].fboA!.width != tw {
            imageLayers[layerIndex].fboA = makeFBO(width: tw, height: th)
            imageLayers[layerIndex].fboB = makeFBO(width: tw, height: th)
        }

        guard let fA = imageLayers[layerIndex].fboA, let fB = imageLayers[layerIndex].fboB else { return }

        // Start ping-pong from layer.texture directly — no copy pass needed
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

            // Build standardized uniform buffer matching ALL translated shader structs
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
                effect.params["g_AnimationSpeed"] ?? 0.15,              // g_AnimationSpeed
                effect.params["g_Strength"] ?? 0.1,                     // g_Strength
                effect.params["g_Scale"] ?? 1.0,                        // g_Scale
                effect.params["g_Ratio"] ?? 1.0,                        // g_Ratio
                effect.params["g_ScrollSpeed"] ?? 0.0,                  // g_ScrollSpeed
                effect.params["g_Direction"] ?? 0.0,                    // g_Direction
                effect.params["g_FlowSpeed"] ?? 1.0,                    // g_FlowSpeed
                effect.params["g_FlowAmp"] ?? 1.0,                      // g_FlowAmp
                effect.params["g_FlowPhaseScale"] ?? 1.0,               // g_FlowPhaseScale
                effect.params["g_SpecularPower"] ?? 1.0,                // g_SpecularPower
                effect.params["g_SpecularStrength"] ?? 1.0,             // g_SpecularStrength
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

        // Result is in `input` — update the scene FBO with the effected layer
        // We re-render this layer to scene FBO using the effected texture
        guard let sceneTex = sceneFBO else { return }
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = sceneTex
        finalPass.colorAttachments[0].loadAction = .load // preserve other layers
        finalPass.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: finalPass) {
            enc.setRenderPipelineState(quadPipeline) // overwrite with effected version
            var fullUV = QuadUniforms(uMin: 0, uMax: 1, vMin: 0, vMax: 1, alpha: 1)
            enc.setVertexBytes(&fullUV, length: MemoryLayout<QuadUniforms>.size, index: 0)
            enc.setFragmentTexture(input, index: 0)
            enc.setFragmentSamplerState(clampSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
    }

    // MARK: - Metal Shaders

    static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadUniforms {
        float uMin, uMax, vMin, vMax, alpha;
    };

    struct QuadVertexOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
    };

    vertex QuadVertexOut quadVertex(uint vid [[vertex_id]],
                                     constant QuadUniforms &u [[buffer(0)]]) {
        float2 pos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uv[4] = { {u.uMin, u.vMax}, {u.uMax, u.vMax}, {u.uMin, u.vMin}, {u.uMax, u.vMin} };
        QuadVertexOut out;
        out.position = float4(pos[vid], 0, 1);
        out.uv = uv[vid];
        out.alpha = u.alpha;
        return out;
    }

    fragment float4 quadFragment(QuadVertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        c.a *= in.alpha;
        return c;
    }

    // --- Particles ---

    struct ParticleVertexOut {
        float4 position [[position]];
        float4 color;
        float pointSize [[point_size]];
        float softness;
    };

    struct ParticleVertexIn {
        float2 position;
        float4 color;
        float size;
        float softness;
    };

    vertex ParticleVertexOut particleVertex(uint vid [[vertex_id]],
                                            constant ParticleVertexIn *particles [[buffer(0)]],
                                            constant float2 &viewSize [[buffer(1)]]) {
        ParticleVertexOut out;
        float2 ndc = particles[vid].position / viewSize * 2.0 - 1.0;
        ndc.y = -ndc.y;
        out.position = float4(ndc, 0, 1);
        out.color = particles[vid].color;
        out.pointSize = particles[vid].size;
        out.softness = particles[vid].softness;
        return out;
    }

    fragment float4 particleFragment(ParticleVertexOut in [[stage_in]],
                                      float2 pointCoord [[point_coord]]) {
        float dist = length(pointCoord - 0.5) * 2.0;
        float alpha;
        if (in.softness > 0.5) {
            alpha = 1.0 - smoothstep(0.0, 1.0, dist);
            alpha *= alpha;
        } else {
            alpha = 1.0 - smoothstep(0.8, 1.0, dist);
        }
        return float4(in.color.rgb, in.color.a * alpha);
    }

    // --- Effects ---

    struct EffectUniforms {
        float time, strength, speed, scale, ratio;
        float scrollSpeed, scrollDirection;
        float texWidth, texHeight;
    };

    struct EffectVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex EffectVertexOut effectVertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
        float2 uv[4] = { {0,1}, {1,1}, {0,0}, {1,0} };
        EffectVertexOut out;
        out.position = float4(pos[vid], 0, 1);
        out.uv = uv[vid];
        return out;
    }

    fragment float4 waterRippleFragment(EffectVertexOut in [[stage_in]],
                                         constant EffectUniforms &u [[buffer(0)]],
                                         texture2d<float> fb [[texture(0)]],
                                         texture2d<float> mask [[texture(1)]],
                                         texture2d<float> normal [[texture(2)]],
                                         sampler s [[sampler(0)]]) {
        float2 uv = in.uv;
        float m = mask.sample(s, uv).r;
        float asp = u.texWidth / u.texHeight;
        float animSp = u.speed * u.speed;
        float2 scroll = float2(sin(u.scrollDirection), cos(u.scrollDirection)) * u.scrollSpeed * u.scrollSpeed * u.time;
        float2 r1 = (uv + u.time * animSp + scroll) * u.scale;
        float2 r2 = (uv * 1.333 - u.time * animSp + scroll) * u.scale;
        r1.x *= asp; r2.x *= asp; r1.y *= u.ratio; r2.y *= u.ratio;
        float3 n1 = normal.sample(s, r1).xyz * 2.0 - 1.0;
        float3 n2 = normal.sample(s, r2).xyz * 2.0 - 1.0;
        float2 n = normalize(float3(n1.xy + n2.xy, n1.z)).xy;
        uv += n * u.strength * u.strength * m;
        return fb.sample(s, uv);
    }

    fragment float4 waterFlowFragment(EffectVertexOut in [[stage_in]],
                                       constant EffectUniforms &u [[buffer(0)]],
                                       texture2d<float> fb [[texture(0)]],
                                       texture2d<float> flow [[texture(1)]],
                                       texture2d<float> phase [[texture(2)]],
                                       sampler s [[sampler(0)]]) {
        float2 uv = in.uv;
        float fp = phase.sample(s, uv).r - 0.5;
        float2 fc = flow.sample(s, uv).rg;
        float2 fm = (fc - float2(0.498)) * 2.0;
        float fa = length(fm);
        float c1 = fract(u.time * u.speed);
        float c2 = fract(u.time * u.speed + 0.5);
        float bl = 2.0 * abs(c1 - 0.5);
        bl = smoothstep(max(0.0, fp), min(1.0, 1.0 + fp), bl);
        float2 o1 = fm * u.strength * 0.1 * c1;
        float2 o2 = fm * u.strength * 0.1 * c2;
        float4 a = fb.sample(s, uv);
        float4 f = mix(fb.sample(s, uv + o1), fb.sample(s, uv + o2), bl);
        return mix(a, f, fa);
    }

    fragment float4 bloomFragment(EffectVertexOut in [[stage_in]],
                                   constant EffectUniforms &u [[buffer(0)]],
                                   texture2d<float> fb [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
        // Simple bloom: extract bright pixels, blur, add back
        float4 c = fb.sample(s, in.uv);
        float brightness = dot(c.rgb, float3(0.299, 0.587, 0.114));
        float bloom = max(0.0, brightness - u.strength) * u.speed; // strength=threshold, speed=intensity
        return float4(c.rgb * (1.0 + bloom * 0.5), c.a);
    }
    """
}

// MARK: - Uniform Structs

struct QuadUniforms {
    var uMin: Float, uMax: Float, vMin: Float, vMax: Float, alpha: Float
}

struct EffectUniforms {
    var time: Float, strength: Float, speed: Float, scale: Float, ratio: Float
    var scrollSpeed: Float, scrollDirection: Float
    var texWidth: Float, texHeight: Float
}

// MARK: - Particle System

struct Particle {
    var x: Float, y: Float, vx: Float, vy: Float
    var size: Float, baseSize: Float, life: Float, age: Float
    var alpha: Float, oscPhase: Float
    var oscPosAmp: Float, oscPosFreq: Float
    var oscAlphaFreq: Float, oscAlphaScale: Float
    var rotation: Float = 0, angularVelocity: Float = 0
}

struct ParticleVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var size: Float
    var softness: Float
}

struct ParticleSystemConfig {
    var ox: Float, oy: Float
    var emitterOffsetX: Float, emitterOffsetY: Float
    var spawnW: Float, spawnH: Float
    var rate: Float, maxcount: Int
    var sizeMin: Float, sizeMax: Float
    var velXMin: Float, velXMax: Float
    var velYMin: Float, velYMax: Float
    var lifetimeMin: Float, lifetimeMax: Float
    var color: SIMD3<Float>
    var alphaMin: Float, alphaMax: Float
    var fadeIn: Float, fadeOut: Float
    var oscPosAmpMin: Float, oscPosAmpMax: Float
    var oscPosFreqMin: Float, oscPosFreqMax: Float
    var oscAlphaFreqMin: Float, oscAlphaFreqMax: Float
    var oscAlphaScaleMin: Float, oscAlphaScaleMax: Float
    var sizeStart: Float, sizeEnd: Float
    var cursorRepel: Float, cursorThreshold: Float
    var drag: Float, starttime: Float
    var soft: Bool, additive: Bool
    // Turbulence
    var turbulenceScale: Float = 0, turbulenceSpeed: Float = 0
    var turbulencePhase: Float = 0, turbulenceStrength: Float = 0
    // Vortex
    var vortexStrength: Float = 0, vortexSpeed: Float = 0
    var vortexCenterX: Float = 0.5, vortexCenterY: Float = 0.5
    // Angular velocity
    var angVelMin: Float = 0, angVelMax: Float = 0
    // Renderer type: 0=sprite, 1=rope, 2=spritetrail
    var rendererType: Int = 0
}

struct ParticleSystem {
    var config: ParticleSystemConfig
    var particles: [Particle] = []
    var timer: Float = 0, elapsed: Float = 0

    private func srand(_ a: Float, _ b: Float) -> Float {
        a <= b ? Float.random(in: a...b) : Float.random(in: b...a)
    }

    mutating func update(dt: Float, mouseX: Float, mouseY: Float) {
        elapsed += dt
        if elapsed < config.starttime { return }

        let cap = min(config.maxcount, 1000)
        timer += dt
        let interval = 1.0 / max(0.01, config.rate)
        while timer >= interval && particles.count < cap {
            particles.append(spawnParticle())
            timer -= interval
        }
        if timer > interval * 10 { timer = 0 }

        var i = 0
        while i < particles.count {
            particles[i].age += dt
            if particles[i].age >= particles[i].life {
                particles[i] = particles[particles.count - 1]
                particles.removeLast()
                continue
            }
            if config.cursorRepel != 0 {
                let dx = particles[i].x - mouseX, dy = particles[i].y - mouseY
                let d = sqrt(dx * dx + dy * dy)
                let thr = config.cursorThreshold
                if thr <= 0 || d < thr {
                    let f = config.cursorRepel * dt / (d + 0.001)
                    particles[i].vx += dx * f; particles[i].vy += dy * f
                }
            }
            if config.drag > 0 {
                let d = powf(1 - config.drag, dt * 60)
                particles[i].vx *= d; particles[i].vy *= d
            }
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].rotation += particles[i].angularVelocity * dt

            // Position oscillation
            if particles[i].oscPosAmp > 0 {
                let ph = particles[i].oscPhase + particles[i].age * particles[i].oscPosFreq * .pi * 2
                particles[i].x += sin(ph) * particles[i].oscPosAmp * dt
            }

            // Turbulence (Perlin-like noise approximation)
            if config.turbulenceStrength > 0 {
                let t = elapsed * config.turbulenceSpeed + config.turbulencePhase
                let px = particles[i].x * config.turbulenceScale
                let py = particles[i].y * config.turbulenceScale
                let nx = sin(px * 12.9898 + py * 78.233 + t) * 0.5
                let ny = cos(px * 39.346 + py * 11.135 + t * 1.3) * 0.5
                particles[i].vx += nx * config.turbulenceStrength * dt
                particles[i].vy += ny * config.turbulenceStrength * dt
            }

            // Vortex
            if config.vortexStrength != 0 {
                let dx = particles[i].x - config.vortexCenterX
                let dy = particles[i].y - config.vortexCenterY
                let d = sqrt(dx * dx + dy * dy) + 0.001
                let force = config.vortexStrength * config.vortexSpeed * dt / d
                particles[i].vx += -dy * force
                particles[i].vy += dx * force
            }

            i += 1
        }
    }

    func render(encoder: MTLRenderCommandEncoder, viewW: Float, viewH: Float) {
        if particles.isEmpty { return }

        func computeAlpha(_ p: Particle) -> Float {
            let progress = p.age / p.life
            var a = p.alpha
            if p.age < config.fadeIn * p.life { a *= p.age / (config.fadeIn * p.life) }
            let fos = 1 - config.fadeOut
            if progress > fos { a *= (1 - (progress - fos) / config.fadeOut) }
            if p.oscAlphaScale > 0 {
                a *= 1 - p.oscAlphaScale * (0.5 + 0.5 * sin(p.oscPhase + p.age * p.oscAlphaFreq * .pi * 2))
            }
            return max(0, min(1, a))
        }

        if config.rendererType == 1 && particles.count >= 2 {
            // Rope renderer: draw connected line segments as triangle strip
            var vertices: [ParticleVertex] = []
            for i in 0..<particles.count {
                let p = particles[i]
                let progress = p.age / p.life
                let ss = config.sizeStart + (config.sizeEnd - config.sizeStart) * progress
                let width = max(1, p.baseSize * ss * viewW) * 0.5
                let alpha = computeAlpha(p)
                let pos = SIMD2<Float>(p.x * viewW, p.y * viewH)

                // Compute perpendicular direction
                var dx: Float = 0, dy: Float = 1
                if i < particles.count - 1 {
                    let next = particles[i + 1]
                    dx = next.x * viewW - pos.x; dy = next.y * viewH - pos.y
                } else if i > 0 {
                    let prev = particles[i - 1]
                    dx = pos.x - prev.x * viewW; dy = pos.y - prev.y * viewH
                }
                let len = sqrt(dx * dx + dy * dy) + 0.001
                let nx = -dy / len * width, ny = dx / len * width
                let c = SIMD4<Float>(config.color.x, config.color.y, config.color.z, alpha)

                vertices.append(ParticleVertex(position: pos + SIMD2(nx, ny), color: c, size: 1, softness: 0))
                vertices.append(ParticleVertex(position: pos - SIMD2(nx, ny), color: c, size: 1, softness: 0))
            }
            if !vertices.isEmpty {
                var vs = SIMD2<Float>(viewW, viewH)
                encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<ParticleVertex>.stride, index: 0)
                encoder.setVertexBytes(&vs, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
            }
        } else {
            // Sprite renderer (default)
            var vertices: [ParticleVertex] = []
            for p in particles {
                let progress = p.age / p.life
                let ss = config.sizeStart + (config.sizeEnd - config.sizeStart) * progress
                let radius = max(1, p.baseSize * ss * viewW)
                let alpha = computeAlpha(p)
                vertices.append(ParticleVertex(
                    position: SIMD2(p.x * viewW, p.y * viewH),
                    color: SIMD4(config.color.x, config.color.y, config.color.z, alpha),
                    size: radius, softness: config.soft ? 1 : 0))
            }
            var vs = SIMD2<Float>(viewW, viewH)
            encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<ParticleVertex>.stride, index: 0)
            encoder.setVertexBytes(&vs, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertices.count)
        }
    }

    private func spawnParticle() -> Particle {
        let s = srand(config.sizeMin, config.sizeMax)
        return Particle(
            x: (config.ox + config.emitterOffsetX) + srand(-config.spawnW, config.spawnW),
            y: (config.oy - config.emitterOffsetY) + srand(-config.spawnH, config.spawnH),
            vx: srand(config.velXMin, config.velXMax), vy: srand(config.velYMin, config.velYMax),
            size: s, baseSize: s,
            life: max(0.1, srand(config.lifetimeMin, config.lifetimeMax)), age: 0,
            alpha: srand(config.alphaMin, config.alphaMax),
            oscPhase: Float.random(in: 0...(.pi * 2)),
            oscPosAmp: srand(config.oscPosAmpMin, config.oscPosAmpMax),
            oscPosFreq: srand(config.oscPosFreqMin, config.oscPosFreqMax),
            oscAlphaFreq: srand(config.oscAlphaFreqMin, config.oscAlphaFreqMax),
            oscAlphaScale: srand(config.oscAlphaScaleMin, config.oscAlphaScaleMax),
            rotation: Float.random(in: 0...(.pi * 2)),
            angularVelocity: srand(config.angVelMin, config.angVelMax))
    }
}
#endif
