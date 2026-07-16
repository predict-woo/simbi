import Foundation
import Testing

@testable import SimbiAudio

/// Pins the FluidAudio facts the recording algorithm is built on
/// (docs/recording-algorithm.md §0–1). If a FluidAudio bump changes any of
/// these, the cut-point engine's constants must be re-derived — fail loudly.
@Suite("DiarizerPreset")
struct DiarizerPresetTests {
    @Test("frame duration is exactly 0.08 s (1280 samples at 16 kHz)")
    func frameArithmetic() {
        #expect(DiarizerPreset.sampleRate == 16_000)
        #expect(DiarizerPreset.frameDuration == 0.08)
        #expect(DiarizerPreset.frameSamples == 1280)
    }

    @Test("fastV2_1 output latency is ~1.04 s")
    func outputLatency() {
        #expect(abs(DiarizerPreset.outputLatency - 1.04) < 0.0001)
    }
}
