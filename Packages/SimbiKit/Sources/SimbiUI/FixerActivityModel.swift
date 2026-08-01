import CodexKit
import Foundation
import Observation

/// UI state behind the fixer button/popover (SPEC.md §6): coarse status for
/// the button plus a short one-line-per-milestone feed for the popover.
/// Fed by `TranscriptFixer`'s event sink; main-actor like all UI state.
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
        /// Thread archived after the final pass (recording stopped).
        case done
    }

    public struct Event: Identifiable, Equatable {
        public let id = UUID()
        public let date: Date
        public let icon: String
        public let text: String
    }

    public private(set) var status: Status = .off
    /// Newest first, capped — the popover is a glance, not a log.
    public private(set) var events: [Event] = []
    private static let maxEvents = 30

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
        case .passStarted(let summary):
            status = .working
            add(icon: "magnifyingglass", text: summary + "…")
        case .message(let text):
            add(icon: "text.bubble", text: text)
        case .passCompleted(let merged, let failed):
            status = .waiting
            if failed {
                add(icon: "exclamationmark.triangle", text: "Pass failed, will retry on new cues")
            } else if merged > 0 {
                add(
                    icon: "checkmark.circle",
                    text: merged == 1
                        ? "Merged 1 fix into the transcript"
                        : "Merged \(merged) fixes into the transcript")
            }
        case .archived:
            status = .done
            add(icon: "moon.zzz", text: "Done: all cues reviewed")
        }
    }

    private func add(icon: String, text: String) {
        events.insert(Event(date: .now, icon: icon, text: text), at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
    }
}
