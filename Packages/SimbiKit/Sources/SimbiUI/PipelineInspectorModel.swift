import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// UI-side accumulator for the Pipeline Inspector window: subscribes to
/// the note pipeline's inspector stream and folds it into
/// `InspectorTimelineState` (the pure reducer that lives in SimbiAudio).
///
/// Observation is deliberately two-tier: the hot per-batch state is
/// `@ObservationIgnored` and read by the timeline Canvas on its own
/// 30 Hz `TimelineView` clock, while `summaryTick` — bumped only when a
/// record, engine event or upload event actually arrived (≤ ~13 Hz) — is
/// the anchor the meter/card/log sections observe. A ~100 Hz PCM batch
/// cadence never causes ~100 Hz SwiftUI invalidation.
@MainActor
@Observable
public final class PipelineInspectorModel {
    public enum Phase: Equatable {
        /// Subscribed, but the note isn't recording yet.
        case waiting
        case live
        /// The session stopped; state stays visible (late cue text still
        /// arrives), and a new session flips back to `.live`.
        case ended
    }

    private(set) var phase: Phase = .waiting
    private(set) var summaryTick = 0

    @ObservationIgnored private(set) var state = InspectorTimelineState()
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    /// Session-local seconds of audio captured (the live head).
    var elapsed: TimeInterval {
        guard let latest = state.latest else { return 0 }
        return latest.sessionBaseSeconds + TimeInterval(latest.samplesFed) / 16000
    }

    func attach(_ recorder: RecordingController) {
        guard task == nil else { return }
        if Flags.uiPreview {
            // Design-review mode: a scripted session through the real
            // engine, no recording needed (see InspectorPreviewDriver).
            let driver = InspectorPreviewDriver()
            task = Task { [weak self] in
                await self?.consume(driver.stream())
            }
            return
        }
        task = Task { [weak self] in
            let stream = await recorder.inspectorUpdates()
            await self?.consume(stream)
        }
    }

    private func consume(_ stream: AsyncStream<InspectorUpdate>) async {
        for await update in stream {
            guard !Task.isCancelled else { return }
            state.apply(update)
            phase = update.recording ? .live : .ended
            if !update.records.isEmpty || !update.events.isEmpty
                || !update.uploadEvents.isEmpty
            {
                summaryTick &+= 1
            }
        }
    }

    /// Cancels the subscription; the pipeline notices the stream
    /// terminating and turns the engine trace back off.
    func detach() {
        task?.cancel()
        task = nil
    }
}
