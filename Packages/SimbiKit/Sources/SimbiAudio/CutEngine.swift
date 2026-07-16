import Foundation

/// The cut-point decision engine: frame labeling (§4), run smoother (§5) and
/// buffer manager (§6) of docs/recording-algorithm.md, which is normative for
/// every rule here. Pure and deterministic: frames in, actions out — no IO,
/// no clocks (invariant §13.6).
///
/// All indices are session-local diarizer frames (80 ms, 1280 samples).

/// Constants from the algorithm guide §1 (frame counts are normative).
public enum CutConstants {
    public static let activeProbability: Float = 0.5
    public static let minSpeechFrames = 3
    public static let minSilenceFrames = 2
    public static let silenceDiscardFrames = 25
    public static let maxBufferFrames = 125
    public static let flushLookbackFrames = 37
    public static let stopPadSeconds = 2.0
    public static let ringTargetSeconds = 15.0
}

/// Per-frame label (§4).
public enum FrameLabel: Equatable, Sendable {
    case silence
    case speech(slot: Int)

    var isSpeech: Bool {
        if case .speech = self { return true }
        return false
    }

    var slot: Int? {
        if case .speech(let s) = self { return s }
        return nil
    }
}

/// Labels one finalized frame from its 4 slot probabilities (§4):
/// SILENCE if no slot ≥ 0.5, else argmax over active slots (tie → lowest).
public func labelFrame(probabilities p: ArraySlice<Float>) -> FrameLabel {
    var best: (slot: Int, prob: Float)?
    for (i, prob) in p.enumerated() where prob >= CutConstants.activeProbability {
        if prob > (best?.prob ?? -1) {
            best = (i, prob)
        }
    }
    guard let best else { return .silence }
    return .speech(slot: best.slot)
}

/// A maximal same-label frame run `[start, end)` (§3).
public struct Run: Equatable, Sendable {
    public var label: FrameLabel
    public var start: Int
    public var end: Int

    public var length: Int { end - start }
}

/// Actions the engine asks the pipeline to perform. Frame-domain only; the
/// pipeline maps frames to note time, assigns cue indices, slices the ring
/// and encodes.
public enum CutAction: Equatable, Sendable {
    /// Encode and upload `[startFrame, endFrame) · 1280` samples as one cue.
    case flush(FlushCommand)
    /// Emit a `NOTE gap` block for a discarded ≥ 2 s silence.
    case gap(startFrame: Int, endFrame: Int)
}

public enum FlushReason: Equatable, Sendable {
    case speakerSwitch
    case longSilence
    case maxBuffer
    case stop
}

public struct FlushCommand: Equatable, Sendable {
    public let startFrame: Int
    /// Exclusive; trailing silence items are already trimmed (§6.3 step 1).
    public let endFrame: Int
    public let speaker: Int
    public let reason: FlushReason
    /// True when this cue continues the previous same-speaker cue
    /// mid-sentence (a MAX_BUFFER cut preceded it) — renders
    /// `NOTE continuation`.
    public let continuation: Bool
}

// MARK: - Run smoother (§5)

/// Smoother output event, delivered in order to the buffer manager.
enum SmootherEvent {
    /// Immutable committed run. `successor` is the run following it — known
    /// at commit time (§5 commit rule) and used for the glue decision. nil
    /// only for the final run committed at stop.
    case committed(Run, successor: Run?)
    /// The open run passed or grew beyond its min length (gated, §5).
    case progress(Run)
}

/// Converts the per-frame label stream into committed runs plus gated
/// open-run progress (§5). The only component that may relabel frames.
struct RunSmoother {
    private(set) var current: Run?
    private var pending: [Run] = []
    private var lastCommittedLabel: FrameLabel?

    private static func minLength(_ label: FrameLabel) -> Int {
        label.isSpeech ? CutConstants.minSpeechFrames : CutConstants.minSilenceFrames
    }

    /// Pushes one finalized frame; returns events in emission order.
    /// Per-frame ordering (§6.4): commits precede the open-run progress.
    mutating func push(frame f: Int, label: FrameLabel) -> [SmootherEvent] {
        var events: [SmootherEvent] = []

        guard var open = current else {
            current = Run(label: label, start: f, end: f + 1)
            return events
        }

        if label == open.label {
            open.end = f + 1
            current = open
            events.append(contentsOf: commitReady())
            if open.length >= Self.minLength(open.label) {
                events.append(.progress(open))
            }
            return events
        }

        // Label changed: close current, open the new run.
        pending.append(open)
        current = Run(label: label, start: f, end: f + 1)

        // Immediate absorption of the just-closed run if too short (§5).
        if let closed = pending.last, closed.length < Self.minLength(closed.label) {
            pending.removeLast()
            var reopened: Run?
            if var predecessor = pending.popLast() {
                // Relabel the short run to its predecessor's label; merge.
                predecessor.end = closed.end
                if predecessor.label == current?.label {
                    reopened = predecessor
                } else {
                    pending.append(predecessor)
                }
            } else {
                // Virtual SILENCE before frame 0, or the last committed run:
                // the short run takes that label and stands alone.
                var relabeled = closed
                relabeled.label = lastCommittedLabel ?? .silence
                if relabeled.label == current?.label {
                    reopened = relabeled
                } else {
                    pending.append(relabeled)
                }
            }
            if var reopened {
                // The merge made the predecessor adjacent to the same-label
                // open run: it is open again (§5 reopen-merge).
                reopened.end = current!.end
                current = reopened
                events.append(contentsOf: commitReady())
                if reopened.length >= Self.minLength(reopened.label) {
                    events.append(.progress(reopened))
                }
                return events
            }
        }

        events.append(contentsOf: commitReady())
        return events
    }

    /// Commit rule (§5): a pending run is immutable once its successor has
    /// reached its own min length.
    private mutating func commitReady() -> [SmootherEvent] {
        var events: [SmootherEvent] = []
        while let first = pending.first {
            let successor = pending.count > 1 ? pending[1] : current
            guard let successor, successor.length >= Self.minLength(successor.label) else {
                break
            }
            pending.removeFirst()
            lastCommittedLabel = first.label
            events.append(.committed(first, successor: successor))
        }
        return events
    }

    /// Stop (§10.1 step 5): close the open run, absorb it if short, commit
    /// everything unconditionally.
    mutating func stop() -> [SmootherEvent] {
        if var open = current {
            current = nil
            if open.length < Self.minLength(open.label), var predecessor = pending.popLast() {
                predecessor.end = open.end
                pending.append(predecessor)
            } else if open.length < Self.minLength(open.label), pending.isEmpty {
                open.label = lastCommittedLabel ?? .silence
                pending.append(open)
            } else {
                pending.append(open)
            }
        }
        var events: [SmootherEvent] = []
        while !pending.isEmpty {
            let run = pending.removeFirst()
            lastCommittedLabel = run.label
            events.append(.committed(run, successor: pending.first))
        }
        return events
    }
}

// MARK: - Buffer manager (§6)

/// Owns the (single) upload buffer, decides every flush and gap (§6).
struct BufferManager {
    private struct Item {
        var isSpeech: Bool
        var start: Int
        var end: Int
    }

    private var items: [Item] = []
    private var speaker: Int?
    private var bufferStart = 0
    /// Frames of the open run already shipped by a MAX_BUFFER hard cut.
    private var openConsumedUpTo = 0
    /// Speaker of the last MAX_BUFFER flush (§6.2 / §6.3 step 10).
    private var pendingContinuation: Int?
    /// Latches (§5: threshold actions fire once per run), keyed by run start.
    private var longSilenceLatch: Int?
    private var switchLatch: Int?
    /// Finite only during stop (§7, §10.1).
    private var realFrameEnd = Int.max

    private var bufferEndFrame: Int { items.last?.end ?? bufferStart }
    private var bufferFrameCount: Int { items.reduce(0) { $0 + ($1.end - $1.start) } }
    private var isEmpty: Bool { items.isEmpty }

    // MARK: Event handlers (§6.1)

    mutating func handle(_ event: SmootherEvent) -> [CutAction] {
        switch event {
        case .committed(let run, let successor):
            return handleCommitted(run, successor: successor)
        case .progress(let run):
            return handleProgress(run)
        }
    }

    private mutating func handleCommitted(_ run: Run, successor: Run?) -> [CutAction] {
        var actions: [CutAction] = []
        switch run.label {
        case .speech(let s):
            if !isEmpty, speaker != s {
                // Safety net for bursts; normally the open-run check flushed.
                actions.append(contentsOf: flush(.speakerSwitch))
            }
            let start = max(run.start, openConsumedUpTo)
            if start < run.end {
                if isEmpty {
                    speaker = s
                    bufferStart = start
                }
                items.append(Item(isSpeech: true, start: start, end: run.end))
            }
            // The successor is stable at commit time; it may already count
            // toward the buffered total (§6.2).
            actions.append(contentsOf: checkMaxBuffer(open: successor))
        case .silence:
            let effectiveEnd = min(run.end, realFrameEnd)
            if effectiveEnd - run.start >= CutConstants.silenceDiscardFrames {
                if !isEmpty {
                    // Safety net: the run can close before its latched ≥ 25
                    // progress event fires (§6.1); flushing first keeps
                    // outbox entries in timestamp order.
                    actions.append(contentsOf: flush(.longSilence))
                }
                actions.append(.gap(startFrame: run.start, endFrame: effectiveEnd))
            } else if !isEmpty, let speaker, successor?.label == .speech(slot: speaker) {
                items.append(Item(isSpeech: false, start: run.start, end: run.end))
            }
        // else: drop (leading silence, or silence before a different
        // speaker — the switch flush's trailing trim makes it moot).
        }
        return actions
    }

    private mutating func handleProgress(_ run: Run) -> [CutAction] {
        switch run.label {
        case .speech(let s):
            if !isEmpty, s != speaker {
                // Primary speaker-switch cut, latched once per run (§6.1).
                guard switchLatch != run.start else { return [] }
                switchLatch = run.start
                return flush(.speakerSwitch)
            }
            return checkMaxBuffer(open: run)
        case .silence:
            // Real frames only: pad frames beyond realFrameEnd never trigger
            // a long-silence flush (§10.1 — the stop path owns the final
            // flush).
            let effectiveLength = min(run.end, realFrameEnd) - run.start
            guard !isEmpty, effectiveLength >= CutConstants.silenceDiscardFrames,
                longSilenceLatch != run.start
            else { return [] }
            longSilenceLatch = run.start
            return flush(.longSilence)
        }
    }

    /// Sets the real-audio bound before stop-time events are processed, so
    /// committed-run handling clamps gap extents to real audio (§10.1).
    mutating func beginStop(realFrameEnd: Int) {
        self.realFrameEnd = realFrameEnd
    }

    /// Stop (§10.1 step 6): whatever remains buffered flushes now.
    mutating func stop() -> [CutAction] {
        flush(.stop)
    }

    // MARK: checkMaxBuffer (§6.2)

    private mutating func checkMaxBuffer(open: Run?) -> [CutAction] {
        var openExtent = 0
        var openStart = 0
        var openMatches = false
        if let open, case .speech(let s) = open.label,
            open.length >= CutConstants.minSpeechFrames,
            isEmpty || s == speaker
        {
            openMatches = true
            openStart = max(open.start, openConsumedUpTo)
            openExtent = max(0, open.end - openStart)
        }
        let total = bufferFrameCount + openExtent
        guard total >= CutConstants.maxBufferFrames else { return [] }

        let bufEnd = bufferEndFrame + openExtent

        // Latest item boundary within the lookback window (§6.2): every
        // silence↔speech transition inside the buffer, plus the boundary
        // between the buffered items and the open run.
        var boundaries = items.dropFirst().map(\.start)
        if bufferEndFrame > bufferStart {
            boundaries.append(bufferEndFrame)
        }
        let candidate =
            boundaries
            .filter { bufEnd - $0 <= CutConstants.flushLookbackFrames && $0 > bufferStart }
            .max()

        if let cut = candidate {
            return flushPrefix(upTo: cut)
        }

        // Hard cut through the open run at its newest stable frame.
        guard let open, openMatches else { return [] }
        if isEmpty {
            speaker = open.label.slot!
            bufferStart = openStart
        }
        items.append(Item(isSpeech: true, start: openStart, end: open.end))
        openConsumedUpTo = open.end
        return flush(.maxBuffer)
    }

    // MARK: flush (§6.3)

    private mutating func flush(_ reason: FlushReason) -> [CutAction] {
        // 1. Trim trailing silence items (they stay on the timeline,
        //    uncovered by the cue).
        while let last = items.last, !last.isSpeech {
            items.removeLast()
        }
        // 2. No speech → no cue; the broken stream also consumes any
        //    pending continuation.
        guard let speaker, items.contains(where: \.isSpeech) else {
            items.removeAll()
            self.speaker = nil
            pendingContinuation = nil
            return []
        }
        let command = FlushCommand(
            startFrame: bufferStart,
            endFrame: min(items.last!.end, realFrameEnd),
            speaker: speaker,
            reason: reason,
            continuation: pendingContinuation == speaker)
        pendingContinuation = (reason == .maxBuffer) ? speaker : nil
        items.removeAll()
        self.speaker = nil
        return [.flush(command)]
    }

    /// MAX_BUFFER boundary cut: flush items before `cut`, keep the tail
    /// buffered from `cut` (§6.2, §6.3 step 11).
    private mutating func flushPrefix(upTo cut: Int) -> [CutAction] {
        let kept = items.filter { $0.end > cut }
        var prefix = items.filter { $0.end <= cut }
        while let last = prefix.last, !last.isSpeech {
            prefix.removeLast()
        }

        var actions: [CutAction] = []
        if let speaker, prefix.contains(where: \.isSpeech) {
            actions.append(
                .flush(
                    FlushCommand(
                        startFrame: bufferStart,
                        endFrame: min(prefix.last!.end, realFrameEnd),
                        speaker: speaker,
                        reason: .maxBuffer,
                        continuation: pendingContinuation == speaker)))
            pendingContinuation = speaker
        } else {
            pendingContinuation = nil
        }
        items = kept
        bufferStart = cut
        return actions
    }
}

// MARK: - Engine facade

/// Ties smoother and manager together. The smoother emits events in the
/// fixed per-frame order (§6.4: commits, then switch / longSilence / MAX
/// via the progress event), and the manager handles them in order.
public struct CutEngine {
    private var smoother = RunSmoother()
    private var manager = BufferManager()
    public private(set) var nextFrameIndex = 0

    public init() {}

    /// Announces the real-audio bound at the start of the stop sequence
    /// (§10.1 step 2), BEFORE the stop-pad's forced-silence frames are
    /// pushed — pad frames must never trigger flushes or count into gaps.
    public mutating func beginStop(realFrameEnd: Int) {
        manager.beginStop(realFrameEnd: realFrameEnd)
    }

    /// Pushes one finalized frame's label; returns actions in order.
    public mutating func push(label: FrameLabel) -> [CutAction] {
        let frame = nextFrameIndex
        nextFrameIndex += 1
        var actions: [CutAction] = []
        for event in smoother.push(frame: frame, label: label) {
            actions.append(contentsOf: manager.handle(event))
        }
        return actions
    }

    /// Stop (§10.1 steps 5–6). `realFrameEnd` clamps gap/cue extents; frames
    /// at or beyond it were force-labeled SILENCE by the pipeline (§7).
    public mutating func stop(realFrameEnd: Int) -> [CutAction] {
        manager.beginStop(realFrameEnd: realFrameEnd)
        var actions: [CutAction] = []
        for event in smoother.stop() {
            actions.append(contentsOf: manager.handle(event))
        }
        actions.append(contentsOf: manager.stop())
        return actions
    }
}
