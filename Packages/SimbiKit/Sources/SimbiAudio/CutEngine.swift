import Foundation

/// The cuts, flushes and discards engine of docs/recording-algorithm.md (v2)
/// §5, which is normative for every rule here. Consumes the aligned record
/// stream — one `{vadActive, speakerProbs}` record per 80 ms frame (§4) —
/// and decides uploads. Pure and deterministic: records in, flush commands
/// out — no IO, no clocks (§4.1 consequence 2). Discards (§5.1) emit no
/// command; they only advance `flushedUpTo`, which the pipeline mirrors into
/// the ring's eviction floor.
///
/// All indices are session-local frames (80 ms, 1280 samples).

/// Constants from the algorithm guide §2 / §5.2 (frame counts normative).
public enum CutConstants {
    /// A Sortformer slot is active iff p ≥ this (§5.3).
    public static let activeProbability: Float = 0.5
    /// A VAD chunk is speech iff its Silero probability ≥ this (§6 open
    /// decision resolved to the library default).
    public static let vadThreshold: Float = 0.85
    /// R1: cut after this many consecutive silent records.
    public static let silenceCutFrames = 3
    /// R3: flush staging when a silence run reaches this.
    public static let longSilenceFlushFrames = 25
    /// R2: flush when staging exceeds this after a cut.
    public static let stagingFlushFrames = 125
    /// R4: a new speaker must hold dominance this long to trigger.
    public static let speakerStableFrames = 6
    /// R4 branch test: Sortformer reports offsets late by up to this.
    public static let sortLagToleranceFrames = 3
    /// R5: hard bound on the unflushed span — a forced cut fires when
    /// `frontier − flushedUpTo` reaches this (30 s).
    public static let maxUnflushedFrames = 375
    /// R6: trailing silence kept unflushed as pre-roll for resumed speech.
    public static let preRollFrames = 12
    /// §4.1 release clock: records land this far behind live audio.
    public static let pipelineLatencyFrames = 13
    public static let frameSamples = 1280
    public static let vadChunkSamples = 4096
    /// Zeros fed to the models (only) at stop so every real frame gets a
    /// record (§5.4 Stop; the wrappers' latency must be drained).
    public static let stopPadSeconds = 2.0
    public static let ringTargetSeconds = 15.0
}

/// Per-frame Sortformer label. Retained for the live-UI tentative indicator
/// and for scripting fake diarizers in tests.
public enum FrameLabel: Equatable, Sendable {
    case silence
    case speech(slot: Int)

    var isSpeech: Bool {
        if case .speech = self { return true }
        return false
    }

    var slot: Int? {
        if case .speech(let slot) = self { return slot }
        return nil
    }
}

/// dominant(f) (§5.3): nil if no slot is active, else argmax over active
/// slots (tie → lowest slot index). Deliberately VAD-independent.
public func labelFrame(probabilities: ArraySlice<Float>) -> FrameLabel {
    var best: (slot: Int, prob: Float)?
    for (i, prob) in probabilities.enumerated() where prob >= CutConstants.activeProbability {
        if prob > (best?.prob ?? -1) {
            best = (i, prob)
        }
    }
    guard let best else { return .silence }
    return .speech(slot: best.slot)
}

/// Which rule performed a traced cut (Pipeline Inspector attribution).
public enum CutRule: Equatable, Sendable {
    case r1, r4, r5, stop
}

/// One traced engine decision. Emitted only while `traceEnabled` — the
/// Pipeline Inspector's food, never consulted by the engine itself.
public enum CutEvent: Equatable, Sendable {
    case cut(frame: Int, rule: CutRule)
    case flush(FlushCommand)
    case discard(start: Int, end: Int)
    case speakerInit(frame: Int, slot: Int)
    case speakerChange(frame: Int, from: Int, to: Int)
}

public enum FlushReason: Equatable, Sendable {
    /// R3 — a silence run reached 2 s.
    case longSilence
    /// R2 — staging exceeded 10 s after a cut.
    case sizeLimit
    /// R4 — a stable new speaker took over.
    case speakerChange
    /// R5 — 30 s passed without a flushable pause; the boundary is forced.
    case maxLatency
    /// Session stop.
    case stop
}

/// One upload: the staged span `[startFrame, endFrame)`. Uploads and
/// discards together partition the session timeline, in order — every frame
/// is uploaded exactly once, except silence-only spans skipped by a discard,
/// which are uploaded zero times (§5.1 tiling invariant). Discarded audio
/// stays in `audio.webm`; frame numbers are always real-recording positions.
public struct FlushCommand: Equatable, Sendable {
    public let startFrame: Int
    /// Exclusive.
    public let endFrame: Int
    /// nil only before the first stable speaker of the session (§5.3).
    public let speaker: Int?
    public let reason: FlushReason
}

/// §5's two-pointer engine: `flushedUpTo ≤ cutUpTo ≤ frontier`. A cut
/// advances `cutUpTo` (cheap bookkeeping), a flush uploads
/// `[flushedUpTo, cutUpTo)` and catches the pointer up, and a discard
/// advances both pointers past a silence-only span with no upload.
public struct CutEngine {
    public private(set) var flushedUpTo = 0
    public private(set) var cutUpTo = 0
    public private(set) var frontier = 0

    /// Inspector trace (opt-in). Decisions never read it; with
    /// `traceEnabled` false nothing is appended, so the engine stays free.
    public var traceEnabled = false
    public private(set) var trace: [CutEvent] = []

    public private(set) var silenceRun = 0
    public private(set) var previousDominant: Int?
    public private(set) var dominantRun = 0
    private var dominantRunStart = 0
    /// Last frame each slot was dominant — R4's `lastStop` source.
    private var lastDominantFrame: [Int: Int] = [:]
    /// §5.3 unflushedVad: the VAD verdicts of records
    /// `[flushedUpTo, frontier)`, trimmed as `flushedUpTo` advances and
    /// bounded at `maxUnflushedFrames` by R5. Backs the speech guards of
    /// R1, R4 and stop.
    private var unflushedVad: [Bool] = []
    public private(set) var currentSpeaker: Int?

    public init() {}

    /// Returns and empties the trace buffer.
    public mutating func drainTrace() -> [CutEvent] {
        let drained = trace
        trace.removeAll(keepingCapacity: true)
        return drained
    }

    private mutating func traceEvent(_ event: CutEvent) {
        if traceEnabled { trace.append(event) }
    }

    /// §5.3 unflushedVad query: does `[lo, hi)` contain a VAD-active record?
    private func hasSpeech(_ lo: Int, _ hi: Int) -> Bool {
        let start = max(lo, flushedUpTo) - flushedUpTo
        let end = hi - flushedUpTo
        guard start < end else { return false }
        return unflushedVad[start..<end].contains(true)
    }

    /// Pushes one released record (§5.3/§5.4). Rules run in the fixed order
    /// R1 → R3 → R6 → R4 → R5; R2 runs inside every cut. `silenceRun`/
    /// `dominantRun` advance by exactly one per record, so the edge triggers
    /// use `==` — a run can never jump past its threshold.
    public mutating func push(
        vadActive: Bool, probabilities: ArraySlice<Float>
    ) -> [FlushCommand] {
        let frame = frontier
        frontier += 1
        unflushedVad.append(vadActive)
        var commands: [FlushCommand] = []

        if vadActive {
            silenceRun = 0
        } else {
            silenceRun += 1
        }

        // R1 — silence cut. Guard: something to seal — unflushed speech
        // must precede the cut point. Covers session-leading silence AND a
        // flush boundary landing at/inside the run (an R5 cut can do that);
        // without it the cut would set up a pure-silence upload.
        if !vadActive, silenceRun == CutConstants.silenceCutFrames,
            hasSpeech(flushedUpTo, frame + 1)
        {
            cut(frame + 1, rule: .r1, into: &commands)
        }

        // R3 — long-silence flush: the staged speech reaches the transcript
        // promptly during the pause. The silence itself is not cut — R6
        // takes over from here.
        if !vadActive, silenceRun == CutConstants.longSilenceFlushFrames {
            flush(.longSilence, into: &commands)
        }

        // R6 — silence trim: past the R3 point, keep only the trailing
        // pre-roll of the silence unflushed; older silence is discarded,
        // never uploaded. Level-triggered; the staging-empty precondition
        // makes it self-pausing.
        if !vadActive, silenceRun >= CutConstants.longSilenceFlushFrames,
            cutUpTo == flushedUpTo
        {
            let target = frame + 1 - CutConstants.preRollFrames
            if target > cutUpTo {
                discard(target)
            }
        }

        // Dominant-run tracking (§5.3): VAD-independent; an undefined
        // dominant resets the run.
        let dominant = labelFrame(probabilities: probabilities).slot
        if let dominant {
            if dominant == previousDominant {
                dominantRun += 1
            } else {
                dominantRun = 1
                dominantRunStart = frame
            }
            previousDominant = dominant
        } else {
            dominantRun = 0
            previousDominant = nil
        }

        // R4 — speaker change (+ the no-cut/no-flush initialization path).
        // The debounce delays only when the rule runs; newStart/lastStop are
        // original frame numbers, so the decision is identical to an
        // instant one.
        if let dominant, dominantRun == CutConstants.speakerStableFrames {
            if currentSpeaker == nil {
                currentSpeaker = dominant
                traceEvent(.speakerInit(frame: frame, slot: dominant))
            } else if dominant != currentSpeaker,
                let lastStop = lastDominantFrame[currentSpeaker!]
            {
                let newStart = dominantRunStart
                let mid = (lastStop + 1 + newStart) / 2
                if lastStop - CutConstants.sortLagToleranceFrames < cutUpTo
                    || !hasSpeech(flushedUpTo, mid)
                {
                    // Either the boundary was already cut (an R1 silence cut
                    // beat Sortformer, which reports offsets late), or the
                    // would-be upload [flushedUpTo, mid) contains no VAD
                    // speech — a stale lastStop inside an R6-trimmed pause
                    // must not slice out a pure-silence upload.
                    flush(.speakerChange, into: &commands)
                } else {
                    // Direct switch or overlap: midpoint of the gap,
                    // degenerating to the boundary when newStart follows
                    // lastStop immediately.
                    cut(mid, rule: .r4, into: &commands)
                    flush(.speakerChange, into: &commands)
                }
                traceEvent(.speakerChange(frame: frame, from: currentSpeaker!, to: dominant))
                currentSpeaker = dominant
            }
        }
        if let dominant {
            lastDominantFrame[dominant] = frame
        }

        // R5 — max-latency cut: hard 30 s bound on unflushed audio. No
        // explicit flush — the staged span now necessarily exceeds the R2
        // limit, so the size check inside the cut ships it.
        if frontier - flushedUpTo >= CutConstants.maxUnflushedFrames {
            cut(frontier, rule: .r5, into: &commands, sizeReason: .maxLatency)
        }

        assert(flushedUpTo <= cutUpTo && cutUpTo <= frontier)
        assert(unflushedVad.count == frontier - flushedUpTo)
        return commands
    }

    /// Stop (§5.4): a fully silent remainder is discarded (uploading it
    /// would be the pure-silence hallucination case); otherwise everything
    /// released but not yet uploaded goes out in one final upload. The
    /// pipeline must drain the wrappers first so every real frame was
    /// pushed.
    public mutating func stop() -> [FlushCommand] {
        var commands: [FlushCommand] = []
        if frontier > flushedUpTo, !hasSpeech(flushedUpTo, frontier) {
            discard(frontier)
        } else {
            if frontier > cutUpTo {
                cut(frontier, rule: .stop, into: &commands)
            }
            flush(.stop, into: &commands)
        }
        return commands
    }

    /// §5.1 cut(c) with R2 folded in: the size check runs immediately after
    /// every cut, so staging never exceeds the limit *before* a cut. An R5
    /// cut passes `.maxLatency` so its forced upload is labeled honestly.
    private mutating func cut(
        _ point: Int, rule: CutRule, into commands: inout [FlushCommand],
        sizeReason: FlushReason = .sizeLimit
    ) {
        assert(cutUpTo < point && point <= frontier, "cut(\(point)) outside (\(cutUpTo), \(frontier)]")
        cutUpTo = point
        traceEvent(.cut(frame: point, rule: rule))
        if cutUpTo - flushedUpTo > CutConstants.stagingFlushFrames {
            flush(sizeReason, into: &commands)
        }
    }

    /// §5.1 flush(): no-op when staging is empty.
    private mutating func flush(_ reason: FlushReason, into commands: inout [FlushCommand]) {
        guard cutUpTo > flushedUpTo else { return }
        let command = FlushCommand(
            startFrame: flushedUpTo, endFrame: cutUpTo,
            speaker: currentSpeaker, reason: reason)
        commands.append(command)
        traceEvent(.flush(command))
        unflushedVad.removeFirst(cutUpTo - flushedUpTo)
        flushedUpTo = cutUpTo
    }

    /// §5.1 discard(c): advance both pointers past a silence-only span with
    /// no upload. Requires staging empty; only R6 and stop call this, and
    /// both guarantee the skipped records are VAD-silent.
    private mutating func discard(_ point: Int) {
        assert(cutUpTo == flushedUpTo, "discard with staging non-empty")
        assert(
            flushedUpTo < point && point <= frontier,
            "discard(\(point)) outside (\(flushedUpTo), \(frontier)]")
        traceEvent(.discard(start: flushedUpTo, end: point))
        unflushedVad.removeFirst(point - flushedUpTo)
        flushedUpTo = point
        cutUpTo = point
    }
}
