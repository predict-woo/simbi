import Foundation

/// Bounded wait between a clean pipeline stop and the AI-notes trigger
/// (AI Notes spec §3): the final cues' transcriptions arrive
/// asynchronously after `RecordingPipeline.stop()` returns, so the
/// trigger polls the pipeline's read-only drain flag until every reserved
/// cue has been rendered to transcript.vtt — or the bound expires.
///
/// The bound is deliberately finite and generous: a degraded recording
/// (no ChatGPT.app, signed out, offline) never drains, and generation
/// then proceeds with whatever transcript exists — an empty one still
/// skips quietly downstream. Pure polling; it observes the pipeline but
/// never touches its cut/flush/upload machinery.
enum TranscriptDrainWait {
    /// Generous headroom over the upload path's worst clean case
    /// (3 attempts with 1 s + 4 s backoff per segment, 2 in flight).
    static let defaultTimeout: Duration = .seconds(45)
    static let defaultPollInterval: Duration = .milliseconds(250)

    /// Polls `isDrained` until it reports true or `timeout` expires.
    /// Returns whether the queue drained (callers proceed either way; the
    /// result only says whether the transcript is known-complete).
    static func wait(
        timeout: Duration = defaultTimeout,
        pollInterval: Duration = defaultPollInterval,
        isDrained: @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if await isDrained() { return true }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            do {
                try await Task.sleep(for: min(pollInterval, remaining))
            } catch {
                return false  // Cancelled: give up on the drain, stay bounded.
            }
        }
    }
}
