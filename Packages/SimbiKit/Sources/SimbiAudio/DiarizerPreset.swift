import FluidAudio
import Foundation

/// Simbi's diarizer configuration (`balancedV2_1`: same ~1 s latency
/// geometry as `fastV2_1` but a 188-frame FIFO — FluidAudio's best-DER
/// streaming preset) and the derived timing constants the cut-point engine
/// builds on (docs/recording-algorithm.md §0–1).
public enum DiarizerPreset {
    public static let config = SortformerConfig.balancedV2_1

    /// 16 kHz — the pipeline-wide sample rate.
    public static var sampleRate: Int { config.sampleRate }

    /// Exactly 0.08 s (1280 samples) per finalized frame. Derived from the
    /// integer config fields, NOT `config.frameDurationSeconds` — that is a
    /// `Float`, and 0.08 is not representable in it. Cue timestamps are built
    /// from this value, so it must be the exact `Double` quotient.
    public static var frameDuration: TimeInterval {
        TimeInterval(frameSamples) / TimeInterval(sampleRate)
    }

    /// Samples covered by one diarizer output frame.
    public static var frameSamples: Int { config.subsamplingFactor * config.melStride }

    /// ~1.04 s: how far finalized predictions lag realtime. Test seam:
    /// the preset tests pin it; the pipeline uses frame counts instead.
    public static var outputLatency: TimeInterval {
        TimeInterval(config.chunkLen + config.chunkRightContext) * frameDuration
    }
}
