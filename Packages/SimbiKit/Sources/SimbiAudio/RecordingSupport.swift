import Foundation

/// Support types for `RecordingPipeline` (split out for file size only).

/// Sidecar metadata persisted next to each pending segment upload
/// (`.simbi/pending/{cueIndex}.json`, guide §6.3 step 7).
public struct PendingSegment: Codable, Equatable, Sendable {
    public var cueIndex: Int
    public var startSec: TimeInterval
    public var endSec: TimeInterval
    public var speaker: Int
    public var continuation: Bool
}

/// Live-UI snapshot emitted by the pipeline while recording.
public struct RecordingLiveUpdate: Equatable, Sendable {
    /// Note-timeline seconds (base + this session's samples).
    public let elapsed: TimeInterval
    /// Tentative "Speaker N speaking…" indicator slot, nil when silent.
    public let tentativeSpeaker: Int?
}

public enum RecordingPipelineError: Error, Equatable {
    case alreadyRecording
    case audioFileMismatch
    case notRecording
}
