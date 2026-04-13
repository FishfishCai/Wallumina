#if ENABLE_SCENE
import Foundation
import Metal

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
    var turbulenceScale: Float = 0, turbulenceSpeed: Float = 0
    var turbulencePhase: Float = 0, turbulenceStrength: Float = 0
    var vortexStrength: Float = 0, vortexSpeed: Float = 0
    var vortexCenterX: Float = 0.5, vortexCenterY: Float = 0.5
    var angVelMin: Float = 0, angVelMax: Float = 0
    /// Renderer type: 0=sprite, 1=rope, 2=spritetrail
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
