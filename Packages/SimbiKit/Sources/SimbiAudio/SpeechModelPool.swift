import FluidAudio
import Foundation

/// Process-wide pool of loaded speech models. `warmUp()` runs at app
/// launch so that `prepare()` at record time is a cache hit instead of a
/// model load — pressing Record must not wait on models (SPEC.md §6).
///
/// The Silero VAD manager is an actor whose streaming calls take explicit
/// state, so one shared instance serves every stream. Sortformer models
/// hold mutable inference buffers, so their checkout is exclusive: the
/// taking stream keeps its copy for its lifetime and the pool reloads a
/// spare in the background for the next note (loads after the first are
/// served from FluidAudio's on-disk model cache).
public final class SpeechModelPool: @unchecked Sendable {
    public static let shared = SpeechModelPool()

    /// SortformerModels (CoreML handles) is not Sendable; ownership
    /// transfers wholesale from the loading task to the one stream that
    /// checks it out.
    private struct Checkout: @unchecked Sendable {
        let models: SortformerModels
    }

    private let lock = NSLock()
    private var sortformerLoad: Task<Checkout, Error>?
    private var vadLoad: Task<VadManager, Error>?

    /// Starts both model loads unless already loading/loaded. Failures
    /// (e.g. first launch offline) are not cached here — they surface and
    /// retry on the next `prepare()`.
    public func warmUp() {
        lock.lock()
        defer { lock.unlock() }
        _ = sortformerLoadLocked()
        _ = vadLoadLocked()
    }

    /// Exclusive checkout of a loaded Sortformer model set; refills the
    /// pool in the background on success.
    func takeSortformerModels() async throws -> SortformerModels {
        let load = checkOutSortformerLoad()
        let models = try await load.value.models
        refillSortformer()
        return models
    }

    /// The shared VAD manager. A failed load is dropped so the next call
    /// retries.
    func vadManager() async throws -> VadManager {
        let load: Task<VadManager, Error> = lock.withLock { vadLoadLocked() }
        do {
            return try await load.value
        } catch {
            lock.withLock { vadLoad = nil }
            throw error
        }
    }

    private func checkOutSortformerLoad() -> Task<Checkout, Error> {
        lock.withLock {
            let load = sortformerLoadLocked()
            sortformerLoad = nil
            return load
        }
    }

    private func refillSortformer() {
        lock.withLock { _ = sortformerLoadLocked() }
    }

    /// Config must match `SortformerStream`'s diarizer config.
    private func sortformerLoadLocked() -> Task<Checkout, Error> {
        if let load = sortformerLoad { return load }
        let load = Task {
            Checkout(models: try await SortformerModels.loadFromHuggingFace(config: DiarizerPreset.config))
        }
        sortformerLoad = load
        return load
    }

    private func vadLoadLocked() -> Task<VadManager, Error> {
        if let load = vadLoad { return load }
        let load = Task { try await VadManager() }
        vadLoad = load
        return load
    }
}
