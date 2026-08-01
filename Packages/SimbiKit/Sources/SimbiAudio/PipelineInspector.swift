import Foundation

/// Pipeline Inspector data model (spec:
/// docs/superpowers/specs/2026-07-22-pipeline-inspector-design.md).
/// `InspectorUpdate` is what `RecordingPipeline.inspectorUpdates()` emits —
/// small value snapshots plus incremental events, never audio.
/// `InspectorTimelineState` is the pure reducer the UI model wraps; it
/// lives here (UI-free) so it is unit-testable next to the engine.

/// One released record of the aligned stream (§4), as the timeline lanes
/// draw it.
public struct InspectorFrameRecord: Equatable, Sendable {
    public let frame: Int
    public let vadActive: Bool
    public let dominantSlot: Int?
    /// The frame's 4 Sortformer slot probabilities (empty in synthesized
    /// test records — the UI treats missing as silence).
    public let probabilities: [Float]

    public init(frame: Int, vadActive: Bool, dominantSlot: Int?, probabilities: [Float] = []) {
        self.frame = frame
        self.vadActive = vadActive
        self.dominantSlot = dominantSlot
        self.probabilities = probabilities
    }
}

/// Upload-side lifecycle of a flushed segment, keyed by cue index.
/// `.queued` fires at flush time (with the span's geometry); `.finished`
/// when the transcription returns — possibly after the session stopped,
/// which is why the inspector stream outlives `stop()`.
public enum InspectorUploadEvent: Equatable, Sendable {
    case queued(cue: Int, startFrame: Int, endFrame: Int, speaker: Int?, reason: FlushReason)
    case finished(cue: Int, text: String)
}

/// One emission of the inspector stream: engine pointers/state as of now,
/// plus everything that happened since the previous emission.
public struct InspectorUpdate: Sendable {
    public let recording: Bool
    /// Samples fed this session (session-local, like frame indices).
    public let samplesFed: Int
    public let sessionBaseSeconds: TimeInterval
    /// Completed 256 ms VAD chunks (§3.1).
    public let vadChunks: Int
    /// Sortformer frames finalized so far (§3.2; bursts of 6).
    public let sortFramesFinalized: Int
    public let frontier: Int
    public let cutUpTo: Int
    public let flushedUpTo: Int
    public let silenceRun: Int
    public let dominantRun: Int
    public let previousDominant: Int?
    public let currentSpeaker: Int?
    public let uploadQueueDepth: Int
    public let uploadsInFlight: Int
    /// Records released since the last emission (usually 0 or 1).
    public let records: [InspectorFrameRecord]
    /// Engine trace drained since the last emission.
    public let events: [CutEvent]
    public let uploadEvents: [InspectorUploadEvent]

    public init(
        recording: Bool, samplesFed: Int, sessionBaseSeconds: TimeInterval, vadChunks: Int,
        sortFramesFinalized: Int, frontier: Int, cutUpTo: Int, flushedUpTo: Int,
        silenceRun: Int, dominantRun: Int, previousDominant: Int?, currentSpeaker: Int?,
        uploadQueueDepth: Int, uploadsInFlight: Int,
        records: [InspectorFrameRecord], events: [CutEvent],
        uploadEvents: [InspectorUploadEvent]
    ) {
        self.recording = recording
        self.samplesFed = samplesFed
        self.sessionBaseSeconds = sessionBaseSeconds
        self.vadChunks = vadChunks
        self.sortFramesFinalized = sortFramesFinalized
        self.frontier = frontier
        self.cutUpTo = cutUpTo
        self.flushedUpTo = flushedUpTo
        self.silenceRun = silenceRun
        self.dominantRun = dominantRun
        self.previousDominant = previousDominant
        self.currentSpeaker = currentSpeaker
        self.uploadQueueDepth = uploadQueueDepth
        self.uploadsInFlight = uploadsInFlight
        self.records = records
        self.events = events
        self.uploadEvents = uploadEvents
    }
}

/// The inspector stream plumbing, owned by `RecordingPipeline` as one
/// actor-confined value so the actor itself stays lean: continuation and
/// replacement token, the per-batch incremental buffers, and update
/// assembly. With no subscriber every operation is a nil-check no-op.
struct InspectorTap {
    /// The non-engine half of an update's snapshot fields.
    struct Counts {
        var recording: Bool
        var samplesFed: Int
        var sessionBaseSeconds: TimeInterval
        var vadChunks: Int
        var sortFrames: Int
        var uploadQueueDepth: Int
        var uploadsInFlight: Int
    }

    private(set) var continuation: AsyncStream<InspectorUpdate>.Continuation?
    private(set) var token = UUID()
    /// Records released / upload events observed since the last emission.
    var records: [InspectorFrameRecord] = []
    var uploadEvents: [InspectorUploadEvent] = []

    var isActive: Bool { continuation != nil }

    /// Replaces any previous subscriber. Bounded newest-wins buffer: a
    /// slow consumer can never back-pressure the pipeline actor.
    mutating func subscribe(
        onTermination: @escaping @Sendable (UUID) -> Void
    ) -> AsyncStream<InspectorUpdate> {
        continuation?.finish()
        token = UUID()
        let streamToken = token
        let (stream, newContinuation) = AsyncStream.makeStream(
            of: InspectorUpdate.self, bufferingPolicy: .bufferingNewest(256))
        continuation = newContinuation
        newContinuation.onTermination = { _ in onTermination(streamToken) }
        return stream
    }

    /// Returns false when the ending stream was already replaced.
    mutating func terminated(_ endedToken: UUID) -> Bool {
        guard endedToken == token else { return false }
        continuation = nil
        records = []
        uploadEvents = []
        return true
    }

    /// Yields one update from the current state + buffers, draining both
    /// the local buffers and the engine trace.
    mutating func emit(counts: Counts, engine: inout CutEngine) {
        guard let continuation else { return }
        let update = InspectorUpdate(
            recording: counts.recording,
            samplesFed: counts.samplesFed,
            sessionBaseSeconds: counts.sessionBaseSeconds,
            vadChunks: counts.vadChunks,
            sortFramesFinalized: counts.sortFrames,
            frontier: engine.frontier,
            cutUpTo: engine.cutUpTo,
            flushedUpTo: engine.flushedUpTo,
            silenceRun: engine.silenceRun,
            dominantRun: engine.dominantRun,
            previousDominant: engine.previousDominant,
            currentSpeaker: engine.currentSpeaker,
            uploadQueueDepth: counts.uploadQueueDepth,
            uploadsInFlight: counts.uploadsInFlight,
            records: records,
            events: engine.drainTrace(),
            uploadEvents: uploadEvents)
        records.removeAll(keepingCapacity: true)
        uploadEvents.removeAll(keepingCapacity: true)
        continuation.yield(update)
    }
}

/// Pure accumulation of inspector updates into drawable state: frame
/// lanes, segments (with transcript text), merged discard spans, cut
/// marks, and a capped event log with consecutive-R6 coalescing.
public struct InspectorTimelineState: Sendable {
    public struct Span: Equatable, Sendable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    public enum SegmentStatus: Equatable, Sendable {
        case queued
        case done(text: String)
    }

    /// One flushed upload, drawn on the timeline and as a card.
    public struct Segment: Equatable, Sendable, Identifiable {
        public let id: Int  // cue index
        public let startFrame: Int
        public let endFrame: Int
        public let speaker: Int?
        public let reason: FlushReason
        public var status: SegmentStatus
    }

    public struct CutMark: Equatable, Sendable {
        public let frame: Int
        public let rule: CutRule
    }

    public struct LogEntry: Equatable, Sendable, Identifiable {
        public let id: Int
        /// Note-timeline seconds of the triggering frame.
        public let time: TimeInterval
        /// Short rule tag: "R1"…"R6", "STOP".
        public let tag: String
        public var message: String
    }

    public static let maxFrames = 2500
    public static let maxSegments = 40
    public static let maxLogEntries = 60
    public static let maxCutMarks = 200

    public private(set) var frames: [InspectorFrameRecord] = []
    /// Frame index of `frames[0]` once the cap has evicted the prefix.
    public private(set) var firstBufferedFrame = 0
    public private(set) var segments: [Segment] = []
    public private(set) var discards: [Span] = []
    public private(set) var cutMarks: [CutMark] = []
    /// Newest first.
    public private(set) var log: [LogEntry] = []
    public private(set) var latest: InspectorUpdate?

    private var nextLogId = 0
    /// Log entry id of the live R6 trimming run, while one is active.
    private var trimmingLogId: Int?
    private var trimmedFramesInRun = 0

    public init() {}

    public mutating func apply(_ update: InspectorUpdate) {
        latest = update
        for record in update.records {
            append(record)
        }
        let overflow = frames.count - Self.maxFrames
        if overflow > 0 {
            frames.removeFirst(overflow)
            firstBufferedFrame += overflow
        }
        let base = update.sessionBaseSeconds
        for event in update.events {
            apply(event, base: base)
        }
        for event in update.uploadEvents {
            apply(event, base: base)
        }
    }

    /// Frame-index-aware append. Records don't necessarily start at frame
    /// 0 (the inspector can subscribe mid-recording) and may skip frames
    /// (the bounded stream drops oldest under pressure) — the buffer must
    /// stay anchored to real frame numbers or every lane draws shifted.
    private mutating func append(_ record: InspectorFrameRecord) {
        if frames.isEmpty {
            firstBufferedFrame = record.frame
        } else if record.frame < firstBufferedFrame + frames.count {
            // Session-local frames restarted (stop + resume): the old
            // timeline no longer shares an axis with the new session.
            resetTimeline(startingAt: record.frame)
        } else {
            while firstBufferedFrame + frames.count < record.frame {
                frames.append(
                    InspectorFrameRecord(
                        frame: firstBufferedFrame + frames.count,
                        vadActive: false, dominantSlot: nil))
            }
        }
        frames.append(record)
    }

    private mutating func resetTimeline(startingAt frame: Int) {
        frames.removeAll(keepingCapacity: true)
        firstBufferedFrame = frame
        segments.removeAll()
        discards.removeAll()
        cutMarks.removeAll()
        endTrimmingRun()
    }

    private mutating func apply(_ event: CutEvent, base: TimeInterval) {
        switch event {
        case .cut(let frame, let rule):
            cutMarks.append(CutMark(frame: frame, rule: rule))
            if cutMarks.count > Self.maxCutMarks {
                cutMarks.removeFirst(cutMarks.count - Self.maxCutMarks)
            }
            endTrimmingRun()
            let message: String
            switch rule {
            case .r1: message = "silence cut: speech tail sealed into staging"
            case .r4: message = "speaker cut at the turn midpoint"
            case .r5: message = "forced cut: unflushed span hit 30 s"
            case .stop: message = "final cut at session stop"
            }
            addLog(tag: Self.tag(rule), time: base + Self.seconds(frame), message: message)
        case .flush:
            // The matching `.queued` upload event carries the cue index and
            // produces the segment + log entry; here only close any R6 run.
            endTrimmingRun()
        case .discard(let start, let end):
            if let last = discards.last, last.end == start {
                discards[discards.count - 1].end = end
            } else {
                discards.append(Span(start: start, end: end))
            }
            trimmedFramesInRun += end - start
            let message = String(
                format: "trimming silence: %.1f s discarded, never uploaded",
                Double(trimmedFramesInRun) * Self.frameSeconds)
            if let id = trimmingLogId, let index = log.firstIndex(where: { $0.id == id }) {
                log[index].message = message
            } else {
                trimmingLogId = addLog(
                    tag: "R6", time: base + Self.seconds(start), message: message)
            }
        case .speakerInit(let frame, let slot):
            addLog(
                tag: "R4", time: base + Self.seconds(frame),
                message: "first stable speaker → Speaker \(slot + 1) (no cut, no flush)")
        case .speakerChange(let frame, let from, let to):
            addLog(
                tag: "R4", time: base + Self.seconds(frame),
                message: "speaker change: Speaker \(from + 1) → Speaker \(to + 1)")
        }
    }

    private mutating func apply(_ event: InspectorUploadEvent, base: TimeInterval) {
        switch event {
        case .queued(let cue, let startFrame, let endFrame, let speaker, let reason):
            segments.append(
                Segment(
                    id: cue, startFrame: startFrame, endFrame: endFrame,
                    speaker: speaker, reason: reason, status: .queued))
            if segments.count > Self.maxSegments {
                segments.removeFirst(segments.count - Self.maxSegments)
            }
            let speakerSuffix = speaker.map { " [Speaker \($0 + 1)]" } ?? ""
            addLog(
                tag: Self.tag(reason), time: base + Self.seconds(startFrame),
                message: String(
                    format: "flush %.1f s → upload (cue %d)%@",
                    Double(endFrame - startFrame) * Self.frameSeconds, cue, speakerSuffix))
        case .finished(let cue, let text):
            if let index = segments.firstIndex(where: { $0.id == cue }) {
                segments[index].status = .done(text: text)
            }
        }
    }

    private mutating func endTrimmingRun() {
        trimmingLogId = nil
        trimmedFramesInRun = 0
    }

    @discardableResult
    private mutating func addLog(tag: String, time: TimeInterval, message: String) -> Int {
        let id = nextLogId
        nextLogId += 1
        log.insert(LogEntry(id: id, time: time, tag: tag, message: message), at: 0)
        if log.count > Self.maxLogEntries {
            log.removeLast(log.count - Self.maxLogEntries)
        }
        return id
    }

    public static func tag(_ rule: CutRule) -> String {
        switch rule {
        case .r1: "R1"
        case .r4: "R4"
        case .r5: "R5"
        case .stop: "STOP"
        }
    }

    public static func tag(_ reason: FlushReason) -> String {
        switch reason {
        case .sizeLimit: "R2"
        case .longSilence: "R3"
        case .speakerChange: "R4"
        case .maxLatency: "R5"
        case .stop: "STOP"
        }
    }

    static let frameSeconds =
        Double(CutConstants.frameSamples) / 16000
    private static func seconds(_ frame: Int) -> TimeInterval {
        Double(frame) * frameSeconds
    }
}
