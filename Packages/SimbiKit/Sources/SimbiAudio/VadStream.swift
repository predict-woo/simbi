import FluidAudio
import Foundation

/// The Silero VAD as the pipeline sees it (guide §1/§3.1): feed arbitrary
/// sample batches, get back one speech verdict per completed 4096-sample
/// (256 ms) chunk. Abstracted so integration tests can script verdict
/// streams; the real implementation wraps FluidAudio's VadManager.
///
/// Sendable so the pipeline actor may await calls; all streaming state is
/// nevertheless confined to the pipeline actor's call sequence.
public protocol VadStream: AnyObject, Sendable {
    /// Loads the model (may download on first use). Idempotent.
    func prepare() async throws
    /// Fresh streaming state for a new session.
    func resetSession()
    /// Buffers `samples`; returns verdicts for each newly completed chunk,
    /// in order. Verdict granularity is the chunk — the frame mapping
    /// (§3.1 midpoint rule) is the pipeline's job.
    func addAudio(_ samples: [Float]) async throws -> [Bool]
}

/// Production wrapper: VadManager streaming (contiguous, non-overlapping
/// chunks — §1 fact 2), verdict = probability ≥ `CutConstants.vadThreshold`.
/// @unchecked: the pipeline actor confines all calls; VadManager itself is
/// an actor.
public final class SileroVadStream: VadStream, @unchecked Sendable {
    private var manager: VadManager?
    private var state: VadStreamState?
    private var pending: [Float] = []

    public init() {}

    public func prepare() async throws {
        guard manager == nil else { return }
        // Shared warm instance — VadManager is an actor and the streaming
        // state lives in this wrapper, so every stream can use one manager.
        manager = try await SpeechModelPool.shared.vadManager()
    }

    public func resetSession() {
        state = nil
        pending.removeAll()
    }

    public func addAudio(_ samples: [Float]) async throws -> [Bool] {
        guard let manager else { return [] }
        pending.append(contentsOf: samples)
        var verdicts: [Bool] = []
        while pending.count >= CutConstants.vadChunkSamples {
            let chunk = Array(pending.prefix(CutConstants.vadChunkSamples))
            pending.removeFirst(CutConstants.vadChunkSamples)
            let result = try await manager.processStreamingChunk(
                chunk, state: state ?? .initial())
            state = result.state
            verdicts.append(result.probability >= CutConstants.vadThreshold)
        }
        return verdicts
    }
}
