import Foundation

/// The cuts-and-flushes engine of docs/recording-algorithm.md (v2) §5, which
/// is normative for every rule here. Consumes the aligned record stream —
/// one `{vadActive, speakerProbs}` record per 80 ms frame (§4) — and decides
/// uploads. Pure and deterministic: records in, flush commands out — no IO,
/// no clocks (§4.1 consequence 2).
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
    public static let speakerStableFrames = 3
    /// R4 branch test: Sortformer reports offsets late by up to this.
    public static let sortLagToleranceFrames = 3
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
        if case .speech(let s) = self { return s }
        return nil
    }
}

/// dominant(f) (§5.3): nil if no slot is active, else argmax over active
/// slots (tie → lowest slot index). Deliberately VAD-independent.
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

public enum FlushReason: Equatable, Sendable {
    /// R3 — a silence run reached 2 s.
    case longSilence
    /// R2 — staging exceeded 10 s after a cut.
    case sizeLimit
    /// R4 — a stable new speaker took over.
    case speakerChange
    /// Session stop.
    case stop
}

/// One upload: the staged span `[startFrame, endFrame)`. Uploads tile the
/// session timeline — every frame is uploaded exactly once, in order,
/// silences included (§5.1 tiling invariant).
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
/// `[flushedUpTo, cutUpTo)` and catches the pointer up.
public struct CutEngine {
    public private(set) var flushedUpTo = 0
    public private(set) var cutUpTo = 0
    public private(set) var frontier = 0

    private var silenceRun = 0
    private var silenceRunStart = 0
    private var previousDominant: Int?
    private var dominantRun = 0
    private var dominantRunStart = 0
    /// Last frame each slot was dominant — R4's `lastStop` source.
    private var lastDominantFrame: [Int: Int] = [:]
    public private(set) var currentSpeaker: Int?

    public init() {}

    /// Pushes one released record (§5.3/§5.4). Rules run in the fixed order
    /// R1 → R3 → R4; R2 runs inside every cut. `silenceRun`/`dominantRun`
    /// advance by exactly one per record, so the edge triggers use `==` —
    /// a run can never jump past its threshold.
    public mutating func push(
        vadActive: Bool, probabilities: ArraySlice<Float>
    ) -> [FlushCommand] {
        let f = frontier
        frontier += 1
        var commands: [FlushCommand] = []

        if vadActive {
            silenceRun = 0
        } else {
            if silenceRun == 0 { silenceRunStart = f }
            silenceRun += 1
        }

        // R1 — silence cut. Guard: only for a run preceded by speech (a run
        // starting at frame 0 — leading silence — never cuts).
        if !vadActive, silenceRun == CutConstants.silenceCutFrames, silenceRunStart > 0 {
            cut(f + 1, into: &commands)
        }

        // R3 — long-silence flush. The silence itself is not cut; it stays
        // in processing and rides into the next upload (tiling invariant).
        if !vadActive, silenceRun == CutConstants.longSilenceFlushFrames {
            flush(.longSilence, into: &commands)
        }

        // Dominant-run tracking (§5.3): VAD-independent; an undefined
        // dominant resets the run.
        let dominant = labelFrame(probabilities: probabilities).slot
        if let dominant {
            if dominant == previousDominant {
                dominantRun += 1
            } else {
                dominantRun = 1
                dominantRunStart = f
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
            } else if dominant != currentSpeaker,
                let lastStop = lastDominantFrame[currentSpeaker!]
            {
                let newStart = dominantRunStart
                if lastStop - CutConstants.sortLagToleranceFrames < cutUpTo {
                    // The boundary was already cut (an R1 silence cut beat
                    // Sortformer, which reports offsets late).
                    flush(.speakerChange, into: &commands)
                } else {
                    // Direct switch or overlap: midpoint of the gap,
                    // degenerating to the boundary when newStart follows
                    // lastStop immediately.
                    cut((lastStop + 1 + newStart) / 2, into: &commands)
                    flush(.speakerChange, into: &commands)
                }
                currentSpeaker = dominant
            }
        }
        if let dominant {
            lastDominantFrame[dominant] = f
        }

        assert(flushedUpTo <= cutUpTo && cutUpTo <= frontier)
        return commands
    }

    /// Stop (§5.4): everything released but not yet uploaded goes out in one
    /// final upload. The pipeline must drain the wrappers first so that
    /// every real frame was pushed.
    public mutating func stop() -> [FlushCommand] {
        var commands: [FlushCommand] = []
        if frontier > cutUpTo {
            cut(frontier, into: &commands)
        }
        flush(.stop, into: &commands)
        return commands
    }

    /// §5.1 cut(c) with R2 folded in: the size check runs immediately after
    /// every cut, so staging never exceeds the limit *before* a cut.
    private mutating func cut(_ c: Int, into commands: inout [FlushCommand]) {
        assert(cutUpTo < c && c <= frontier, "cut(\(c)) outside (\(cutUpTo), \(frontier)]")
        cutUpTo = c
        if cutUpTo - flushedUpTo > CutConstants.stagingFlushFrames {
            flush(.sizeLimit, into: &commands)
        }
    }

    /// §5.1 flush(): no-op when staging is empty.
    private mutating func flush(_ reason: FlushReason, into commands: inout [FlushCommand]) {
        guard cutUpTo > flushedUpTo else { return }
        commands.append(
            FlushCommand(
                startFrame: flushedUpTo, endFrame: cutUpTo,
                speaker: currentSpeaker, reason: reason))
        flushedUpTo = cutUpTo
    }
}
