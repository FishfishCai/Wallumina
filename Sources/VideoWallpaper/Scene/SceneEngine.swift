#if ENABLE_SCENE
import AppKit
import MetalKit
import AVFoundation

// MARK: - Scene Engine

@MainActor
final class SceneEngine: NSObject, MTKViewDelegate {
    // MARK: Device & pipelines
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let quadPipeline: MTLRenderPipelineState
    let quadBlendPipeline: MTLRenderPipelineState
    let particlePipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let clampSampler: MTLSamplerState

    // MARK: Scene geometry
    var sceneWidth: Float = 1920
    var sceneHeight: Float = 1080
    private var viewWidth: Float = 1920
    private var viewHeight: Float = 1080

    // Scene FBO — all layers composite here before being blitted to the drawable
    var sceneFBO: MTLTexture?

    // MARK: Mouse + parallax
    private var mouseX: Float = 0.5
    private var mouseY: Float = 0.5
    var smoothX: Float = 0.5
    var smoothY: Float = 0.5
    var parallaxEnabled = false
    var parallaxAmount: Float = 0.5
    var parallaxDelay: Float = 0.1

    // MARK: Layers & particles
    var imageLayers: [ImageLayer] = []
    var particleSystems: [ParticleSystem] = []
    private var lastFrameTime: CFTimeInterval = 0
    var totalTime: Float = 0

    // MARK: Effects (populated by SceneEngine extension in SceneLayers.swift)
    var effectPipelines: [String: MTLRenderPipelineState] = [:]
    var effectTextures: [String: MTLTexture] = [:]
    /// Ordered uniform names per compiled effect shader
    var effectUniformLayouts: [String: [String]] = [:]

    lazy var fallbackTexture: MTLTexture? = {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var white: [UInt8] = [255, 255, 255, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        return tex
    }()

    // MARK: Bloom
    var bloomEnabled = false
    var bloomStrength: Float = 1.0
    var bloomThreshold: Float = 0.5
    private var bloomFBO4: MTLTexture?
    private var bloomFBO8: MTLTexture?
    private var bloomPipeline: MTLRenderPipelineState?

    // MARK: Audio
    private var audioPlayer: AVAudioPlayer?
    private var audioMuted = false

    // MARK: Draw-loop control (weak ref — the MTKView owns the delegate)
    private weak var mtkViewRef: MTKView?

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
        self.mtkViewRef = mtkView
    }

    // MARK: - Pause

    /// Stop the render loop and pause audio. Called from WallpaperController.setPaused.
    func setPaused(_ paused: Bool) {
        mtkViewRef?.isPaused = paused
        if paused { audioPlayer?.pause() }
        else if !audioMuted { audioPlayer?.play() }
    }

    // MARK: - Mouse

    func updateMouse(_ x: Float, _ y: Float) { mouseX = x; mouseY = y }

    // MARK: - Audio

    func playSound(at url: URL) {
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.numberOfLoops = -1 // loop forever
        audioPlayer?.volume = audioMuted ? 0 : 0.5
        audioPlayer?.play()
    }

    func setMuted(_ muted: Bool) {
        audioMuted = muted
        audioPlayer?.volume = muted ? 0 : 0.5
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

    // MARK: - Render loop

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

        // --- Render all layers + particles into scene FBO ---
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

        // --- Apply per-layer effect chains via FBO ping-pong ---
        for i in 0..<imageLayers.count {
            guard !imageLayers[i].effects.isEmpty else { continue }
            applyLayerEffects(layerIndex: i, commandBuffer: commandBuffer)
        }

        // --- Blit scene FBO to screen with ZoomFill ---
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
}
#endif
