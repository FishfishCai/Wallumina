#if ENABLE_SCENE
import Foundation
import AVFoundation
import Accelerate

/// Captures system audio output and computes FFT spectrum for shader uniforms
@MainActor
final class AudioCapture {
    private var engine: AVAudioEngine?
    private var tap: AVAudioNode?

    // Spectrum data (updated per audio callback)
    var spectrum16L: [Float] = Array(repeating: 0, count: 16)
    var spectrum16R: [Float] = Array(repeating: 0, count: 16)
    var spectrum32L: [Float] = Array(repeating: 0, count: 32)
    var spectrum32R: [Float] = Array(repeating: 0, count: 32)
    var spectrum64L: [Float] = Array(repeating: 0, count: 64)
    var spectrum64R: [Float] = Array(repeating: 0, count: 64)

    private let fftSize: Int = 512
    private var fftSetup: vDSP_DFT_Setup?

    init() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }

    func cleanup() {
        stop()
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup); fftSetup = nil }
    }

    /// Start capturing audio from the default output device
    func start() {
        // On macOS, capturing system audio requires screen capture or aggregate device
        // For now, use the input microphone as a proxy (picks up ambient sound)
        // Full system audio capture requires ScreenCaptureKit (macOS 13+)
        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        inputNode.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] buffer, _ in
            self?.processAudio(buffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            fputs("[VW-AUDIO] capture start failed: \(error)\n", stderr)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func processAudio(buffer: AVAudioPCMBuffer) {
        guard let fftSetup, let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return }

        let channelCount = Int(buffer.format.channelCount)

        for ch in 0..<min(channelCount, 2) {
            let samples = channelData[ch]
            var realIn = [Float](repeating: 0, count: fftSize)
            var imagIn = [Float](repeating: 0, count: fftSize)
            var realOut = [Float](repeating: 0, count: fftSize)
            var imagOut = [Float](repeating: 0, count: fftSize)

            // Window and copy
            for i in 0..<fftSize {
                let window = 0.5 * (1 - cos(2 * .pi * Float(i) / Float(fftSize)))
                realIn[i] = samples[i] * window
            }

            vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)

            // Compute magnitudes
            var magnitudes = [Float](repeating: 0, count: fftSize / 2)
            for i in 0..<fftSize/2 {
                magnitudes[i] = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i]) / Float(fftSize)
            }

            // Bin into 16/32/64 bands
            let binTo16 = binSpectrum(magnitudes, bands: 16)
            let binTo32 = binSpectrum(magnitudes, bands: 32)
            let binTo64 = binSpectrum(magnitudes, bands: 64)

            MainActor.assumeIsolated {
                if ch == 0 {
                    self.spectrum16L = binTo16
                    self.spectrum32L = binTo32
                    self.spectrum64L = binTo64
                } else {
                    self.spectrum16R = binTo16
                    self.spectrum32R = binTo32
                    self.spectrum64R = binTo64
                }
            }
        }
    }

    private func binSpectrum(_ magnitudes: [Float], bands: Int) -> [Float] {
        let binSize = magnitudes.count / bands
        var result = [Float](repeating: 0, count: bands)
        for i in 0..<bands {
            var sum: Float = 0
            for j in 0..<binSize {
                sum += magnitudes[i * binSize + j]
            }
            result[i] = sum / Float(binSize)
        }
        return result
    }
}

#endif
