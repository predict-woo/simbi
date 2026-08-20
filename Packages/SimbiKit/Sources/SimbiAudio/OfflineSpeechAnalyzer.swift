import FluidAudio
import Foundation

/// Batch VAD + diarization over a whole imported file, aligned onto the
/// 80 ms record grid the import block builder consumes.
public protocol OfflineAnalyzing: Sendable {
    /// Loads models (downloads on first use). Idempotent.
    func prepare() async throws
    /// One record per 80 ms frame covering `samples`.
    func analyze(_ samples: [Float]) async throws -> [ImportFrameRecord]
}

/// Runs Silero VAD in batch mode and FluidAudio's offline Sortformer
/// (fused whole-window graph) over an imported file's samples, then maps
/// both onto `ImportFrameRecord`s. Models come from `SpeechModelPool` so
/// repeat imports share one loaded instance; neither joins app-launch
/// warm-up — the first import pays the download.
public final class OfflineSpeechAnalyzer: OfflineAnalyzing, @unchecked Sendable {
    private var vadManager: VadManager?
    private var diarizer: OfflineSortformerDiarizer?

    public init() {}

    public func prepare() async throws {
        if vadManager == nil { vadManager = try await SpeechModelPool.shared.vadManager() }
        if diarizer == nil { diarizer = try await SpeechModelPool.shared.offlineDiarizer() }
    }

    public func analyze(_ samples: [Float]) async throws -> [ImportFrameRecord] {
        guard let vadManager, let diarizer else { throw OfflineAnalyzerError.notPrepared }
        // Batch VAD: one result per 4096-sample chunk, in order.
        let vadResults = try await vadManager.process(samples)
        let verdicts = vadResults.map { $0.probability >= CutConstants.vadThreshold }
        // Offline Sortformer: fused whole-window inference, stitched into one
        // finalized timeline with globally consistent speaker slots.
        let timeline = try diarizer.processComplete(samples)
        return Self.assembleRecords(
            chunkVerdicts: verdicts,
            predictions: timeline.finalizedPredictions,
            sampleCount: samples.count)
    }

    /// Pure grid alignment (unit-tested): a frame's VAD verdict comes from
    /// the chunk containing its midpoint (same rule as
    /// `RecordingPipeline.releaseRecords`), its dominant slot from
    /// `labelFrame` over the frame's 4 Sortformer probabilities. Missing
    /// tail chunks/frames read as silence / nil dominant.
    static func assembleRecords(
        chunkVerdicts: [Bool], predictions: [Float], sampleCount: Int
    ) -> [ImportFrameRecord] {
        let frames =
            sampleCount / CutConstants.frameSamples
            + (sampleCount % CutConstants.frameSamples == 0 ? 0 : 1)
        let sortFrames = predictions.count / 4
        return (0..<frames).map { f in
            let chunk =
                (f * CutConstants.frameSamples + CutConstants.frameSamples / 2)
                / CutConstants.vadChunkSamples
            let vad = chunk < chunkVerdicts.count && chunkVerdicts[chunk]
            var slot: Int?
            if f < sortFrames {
                slot = labelFrame(probabilities: predictions[(f * 4)..<(f * 4 + 4)]).slot
            }
            return ImportFrameRecord(vadActive: vad, dominantSlot: slot)
        }
    }
}

public enum OfflineAnalyzerError: Error {
    case notPrepared
}
