import FluidAudio
import Foundation
import Observation

/// Warm-up progress for the onboarding download step
/// (docs/superpowers/specs/2026-08-17-onboarding-wizard-design.md).
/// `SpeechModelPool.warmUp()` is the only writer; views observe. Late
/// download callbacks after `ready` are dropped so a background
/// Sortformer refill can never resurrect the download UI.
@MainActor @Observable
public final class ModelWarmupState {
    public enum Phase: Equatable {
        case idle
        /// Fraction 0...1 across both loads (Sortformer dominates).
        case downloading(fraction: Double, detail: String)
        case ready
        case failed(message: String)
    }

    public private(set) var phase: Phase = .idle

    func begin() {
        phase = .downloading(fraction: 0, detail: "Preparing")
    }

    func report(sortformerFraction: Double, detail: String) {
        guard case .downloading = phase else { return }
        phase = .downloading(fraction: sortformerFraction, detail: detail)
    }

    func finish() {
        phase = .ready
    }

    func fail(message: String) {
        phase = .failed(message: message)
    }
}

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

    /// Warm-up progress for the onboarding download step; only `warmUp()`
    /// drives it.
    @MainActor public static let warmupState = ModelWarmupState()

    /// Starts both model loads unless already loading/loaded, publishing
    /// progress to `warmupState`. Failures (e.g. first launch offline) are
    /// not cached here — they surface and retry on the next `warmUp()` or
    /// `prepare()`.
    public func warmUp() {
        lock.lock()
        let sortformer = sortformerLoadLocked(reportingProgress: true)
        let vad = vadLoadLocked()
        lock.unlock()
        Task { @MainActor in
            SpeechModelPool.warmupState.begin()
            do {
                _ = try await sortformer.value
                _ = try await vad.value
                SpeechModelPool.warmupState.finish()
            } catch {
                // Clear the failed loads so a retry restarts them (both
                // tasks have already completed by the time we get here).
                lock.withLock {
                    sortformerLoad = nil
                    vadLoad = nil
                }
                SpeechModelPool.warmupState.fail(
                    message: "Model download failed. Check your connection and retry.")
            }
        }
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

    /// Config must match `SortformerStream`'s diarizer config. Progress is
    /// only attached for `warmUp()`: checkout/refill paths must never
    /// resurrect the onboarding download UI. (VAD is ~1 MB next to
    /// Sortformer's ~235 MB, so it gates readiness but reports nothing.)
    private func sortformerLoadLocked(reportingProgress: Bool = false) -> Task<Checkout, Error> {
        if let load = sortformerLoad { return load }
        var handler: ProgressHandler?
        if reportingProgress {
            handler = { progress in
                let detail: String =
                    switch progress.phase {
                    case .listing: "Preparing"
                    case .downloading(let done, let total):
                        "file \(min(done + 1, total)) of \(total)"
                    case .compiling: "Preparing models"
                    }
                Task { @MainActor in
                    SpeechModelPool.warmupState.report(
                        sortformerFraction: progress.fractionCompleted, detail: detail)
                }
            }
        }
        let load = Task {
            Checkout(
                models: try await SortformerModels.loadFromHuggingFace(
                    config: DiarizerPreset.config, progressHandler: handler))
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
