import CodexKit
import Observation

/// UI state behind the header's fixer button: coarse status for the
/// sparkles pulse, visibility, and tooltip. Fed by `TranscriptFixer`'s
/// event sink; main-actor like all UI state.
@MainActor
@Observable
public final class FixerActivityModel {
    public enum Status: Equatable {
        /// No fixer thread yet (never recorded, or Codex unavailable).
        case off
        /// Thread alive, no pass running.
        case waiting
        /// A pass is running.
        case working
        /// Recording stopped and every cue has been reviewed.
        case done
    }

    public private(set) var status: Status = .off

    public init() {}

    /// A recording (re)started: the fixer thread exists again, even before
    /// its first pass fires an event.
    public func noteRecordingStarted() {
        if status == .off || status == .done {
            status = .waiting
        }
    }

    public func handle(_ event: FixerEvent) {
        switch event {
        case .passStarted: status = .working
        case .passCompleted: status = .waiting
        case .done: status = .done
        }
    }
}
