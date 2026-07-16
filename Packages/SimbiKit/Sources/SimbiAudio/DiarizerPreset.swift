import FluidAudio
import Foundation

/// Simbi's diarizer configuration (SPEC.md §3.1: `fastV2_1`, the ~1 s latency
/// mode) and the derived timing constants the cut-point engine builds on
/// (docs/recording-algorithm.md §0–1).
///
/// M0 scope: this target exists to prove the FluidAudio dependency resolves
/// and the API surface the algorithm guide relies on is real. The pipeline
/// lands in M2.
public enum DiarizerPreset {
    public static let config = SortformerConfig.fastV2_1

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

    /// ~1.04 s: how far finalized predictions lag realtime.
    public static var outputLatency: TimeInterval {
        TimeInterval(config.chunkLen + config.chunkRightContext) * frameDuration
    }
}
