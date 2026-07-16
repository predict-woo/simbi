import FluidAudio
import Foundation

/// The diarizer as the pipeline sees it (guide §0/§7). Abstracted so
/// integration tests can script finalized-prediction streams; the real
/// implementation wraps FluidAudio's SortformerDiarizer.
///
/// Sendable so the pipeline actor may await `prepare()`; all streaming
/// calls are nevertheless confined to the pipeline actor (§0 fact 8).
public protocol DiarizerStream: AnyObject, Sendable {
    /// Loads models (may download on first use). Idempotent.
    func prepare() async throws
    /// Fresh streaming state for a new session — frame indices restart at 0
    /// and slot numbering may reshuffle (§10.2 step 3).
    func resetSession()
    func addAudio(_ samples: [Float])
    /// Non-nil once a full chunk is available (bursts of 6 frames).
    func process() throws -> DiarizerChunkResult?
    /// Drains remaining full-context chunks (§0 fact 7).
    func finalizeSession() throws -> DiarizerChunkResult?
}

/// Production wrapper: SortformerDiarizer, fastV2_1, guide-recommended
/// timeline config (§0: library timeline used only for the tentative
/// live-UI; the cut engine consumes raw finalized predictions).
/// @unchecked: SortformerDiarizer serializes access with an internal lock
/// (§0 fact 8), and the pipeline actor confines all calls regardless.
public final class SortformerStream: DiarizerStream, @unchecked Sendable {
    private let diarizer: SortformerDiarizer

    public init() {
        diarizer = SortformerDiarizer(
            config: .fastV2_1,
            timelineConfig: DiarizerTimelineConfig(
                numSpeakers: 4,
                frameDurationSeconds: Float(DiarizerPreset.frameDuration),
                minFramesOn: 3,
                minFramesOff: 1,
                maxStoredFrames: 0,
                storeSegments: false
            )
        )
    }

    private var prepared = false

    public func prepare() async throws {
        guard !prepared else { return }
        let models = try await SortformerModels.loadFromHuggingFace(config: .fastV2_1)
        diarizer.initialize(models: models)
        prepared = true
    }

    public func resetSession() {
        diarizer.reset()
    }

    public func addAudio(_ samples: [Float]) {
        diarizer.addAudio(samples)
    }

    public func process() throws -> DiarizerChunkResult? {
        try diarizer.process()?.chunkResult
    }

    public func finalizeSession() throws -> DiarizerChunkResult? {
        try diarizer.finalizeSession()?.chunkResult
    }
}

extension DiarizerChunkResult {
    /// Tentative speaker for the live UI indicator: argmax of the newest
    /// tentative frame, nil when silent. Display-only (§0 fact 4).
    public var tentativeSpeaker: Int? {
        guard tentativeFrameCount > 0 else { return nil }
        let last = tentativePredictions.suffix(4)
        return labelFrame(probabilities: last[last.startIndex...]).slot
    }
}
