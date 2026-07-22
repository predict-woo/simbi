import Testing

@testable import SimbiAudio

/// Unit tests for the v2 cuts/flushes/discards engine (guide §5), ported
/// from the scenarios of docs/recording-algorithm-sim.py. Records are
/// synthesized directly — the engine is a pure function of the record
/// stream. Discards emit no command; they are observed via `flushedUpTo`.
@Suite("CutEngine v2")
struct CutEngineTests {
    /// Pushes `count` records with one speaker dominant (or silence probs
    /// when `slot` is nil), VAD per `vadActive`.
    private func push(
        _ engine: inout CutEngine, count: Int, vadActive: Bool, slot: Int?
    ) -> [FlushCommand] {
        var commands: [FlushCommand] = []
        for _ in 0..<count {
            var probs: [Float] = [0, 0, 0, 0]
            if let slot { probs[slot] = 0.9 }
            commands.append(
                contentsOf: engine.push(vadActive: vadActive, probabilities: probs[...]))
        }
        return commands
    }

    @Test("R1 cuts at 3 silent records, R3 flushes at 25, R6 trims after")
    func silenceCutAndLongSilenceFlush() {
        var engine = CutEngine()
        // Speech f0–39, then silence.
        #expect(push(&engine, count: 40, vadActive: true, slot: 0).isEmpty)
        // Silence f40–63: R1 fires at f42 -> cut(43).
        #expect(push(&engine, count: 24, vadActive: false, slot: nil).isEmpty)
        #expect(engine.cutUpTo == 43)
        // f64 is the 25th silent record: R3 flushes, then R6 makes its
        // first discard (target 65 - 12 = 53).
        let commands = push(&engine, count: 1, vadActive: false, slot: nil)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 43, speaker: 0, reason: .longSilence)
            ])
        #expect(engine.flushedUpTo == 53)
        // Continuing silence never re-flushes (edge trigger); R6 keeps
        // sliding the discard pointer, retaining the 12-frame pre-roll.
        #expect(push(&engine, count: 50, vadActive: false, slot: nil).isEmpty)
        #expect(engine.flushedUpTo == 115 - CutConstants.preRollFrames)
    }

    @Test("leading silence never cuts; R6 discards it instead of uploading")
    func leadingSilenceDiscarded() {
        var engine = CutEngine()
        // A silence run starting at frame 0: R1's seal guard blocks the cut
        // (no unflushed speech), R3's flush is a no-op, and R6 trims the
        // dead air down to the pre-roll.
        #expect(push(&engine, count: 60, vadActive: false, slot: nil).isEmpty)
        #expect(engine.flushedUpTo == 60 - CutConstants.preRollFrames)
        #expect(engine.cutUpTo == engine.flushedUpTo)
        // Speech f60–79, then a pause: R1 cuts at f82 -> cut(83), R3
        // flushes at f104. The upload starts at the discard point — its
        // leading silence is exactly the retained pre-roll.
        #expect(push(&engine, count: 20, vadActive: true, slot: 1).isEmpty)
        let commands = push(&engine, count: 25, vadActive: false, slot: nil)
        #expect(
            commands == [
                FlushCommand(startFrame: 48, endFrame: 83, speaker: 1, reason: .longSilence)
            ])
    }

    @Test("R2 flushes when a cut pushes staging past 10 s")
    func sizeFlush() {
        var engine = CutEngine()
        // Speech f0–59, 3-frame pause (cut at 63), speech f63–127, pause:
        // the second R1 cut lands at 131 > 125 -> size flush of everything.
        _ = push(&engine, count: 60, vadActive: true, slot: 0)
        _ = push(&engine, count: 3, vadActive: false, slot: nil)
        #expect(engine.cutUpTo == 63)
        _ = push(&engine, count: 65, vadActive: true, slot: 0)
        let commands = push(&engine, count: 3, vadActive: false, slot: nil)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 131, speaker: 0, reason: .sizeLimit)
            ])
    }

    @Test("R5 forces an upload after 30 s without a flushable pause")
    func maxLatencyFlush() {
        var engine = CutEngine()
        // Unbroken speech: nothing cuts until the unflushed span reaches
        // maxUnflushedFrames at f374, where R5's forced cut trips the size
        // check and ships the whole span.
        var commands = push(&engine, count: 374, vadActive: true, slot: 0)
        #expect(commands.isEmpty)
        commands = push(&engine, count: 1, vadActive: true, slot: 0)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 375, speaker: 0, reason: .maxLatency)
            ])
        // And again exactly one span later.
        commands = push(&engine, count: 375, vadActive: true, slot: 0)
        #expect(
            commands == [
                FlushCommand(startFrame: 375, endFrame: 750, speaker: 0, reason: .maxLatency)
            ])
    }

    @Test("R6 trims long silence to a 1 s pre-roll before resumed speech")
    func silenceTrimPreRoll() {
        var engine = CutEngine()
        _ = push(&engine, count: 40, vadActive: true, slot: 0)  // f0–39
        // 12 s of silence f40–189: R1 cut at 43, R3 flush, then R6 slides
        // the discard pointer keeping the trailing 12 frames.
        _ = push(&engine, count: 150, vadActive: false, slot: nil)
        #expect(engine.flushedUpTo == 190 - CutConstants.preRollFrames)
        // Speech resumes f190–229; the next upload leads with exactly the
        // pre-roll (178 = 190 - 12), riding in as acoustic context.
        _ = push(&engine, count: 40, vadActive: true, slot: 0)
        let commands = push(&engine, count: 25, vadActive: false, slot: nil)
        #expect(
            commands == [
                FlushCommand(startFrame: 178, endFrame: 233, speaker: 0, reason: .longSilence)
            ])
    }

    @Test("a phantom speaker in trimmed silence never uploads pure silence")
    func phantomSpeakerInSilence() {
        var engine = CutEngine()
        _ = push(&engine, count: 40, vadActive: true, slot: 0)  // A f0–39
        // Long VAD silence f40–138 (R1 cut, R3 flush, R6 trimming), then a
        // 1-frame Sortformer flicker of A at f139 — a stale lastStop inside
        // the pre-roll window.
        _ = push(&engine, count: 99, vadActive: false, slot: nil)
        _ = push(&engine, count: 1, vadActive: false, slot: 0)
        // B "stable" for 6 frames, still VAD-silent: lastStop(A)=139 defeats
        // the already-cut test, so only the speech-before-mid guard stands
        // between this and a pure-silence upload of the pre-roll (§5.4 R4).
        let commands = push(&engine, count: 6, vadActive: false, slot: 1)
        #expect(commands.isEmpty)
        #expect(engine.currentSpeaker == 1)
    }

    @Test("R4 branch 1: VAD already cut the boundary -> flush only")
    func speakerChangeAfterPause() {
        var engine = CutEngine()
        // A f0–49; silence f50–59 (R1 cut at 53); B from f60.
        _ = push(&engine, count: 50, vadActive: true, slot: 0)
        _ = push(&engine, count: 10, vadActive: false, slot: nil)
        #expect(engine.cutUpTo == 53)
        // B stable at its 6th record (f65): lastStop(A)=49, 49-3 < 53.
        var commands = push(&engine, count: 5, vadActive: true, slot: 1)
        #expect(commands.isEmpty)
        commands = push(&engine, count: 1, vadActive: true, slot: 1)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 53, speaker: 0, reason: .speakerChange)
            ])
        #expect(engine.currentSpeaker == 1)
    }

    @Test("R4 branch 2: direct switch cuts at the boundary midpoint")
    func speakerChangeDirectSwitch() {
        var engine = CutEngine()
        // A f0–49, B f50– with no silence: stable at f55,
        // midpoint (49+1+50)/2 = 50.
        _ = push(&engine, count: 50, vadActive: true, slot: 0)
        let commands = push(&engine, count: 6, vadActive: true, slot: 1)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 50, speaker: 0, reason: .speakerChange)
            ])
        #expect(engine.currentSpeaker == 1)
    }

    @Test("sub-stability flicker never triggers R4")
    func flickerAbsorbed() {
        var engine = CutEngine()
        _ = push(&engine, count: 30, vadActive: true, slot: 0)
        // 5 frames of B (< speakerStableFrames = 6), then A again: the
        // 0.4 s excursion is absorbed into A's turn.
        #expect(push(&engine, count: 5, vadActive: true, slot: 1).isEmpty)
        #expect(push(&engine, count: 30, vadActive: true, slot: 0).isEmpty)
        #expect(engine.currentSpeaker == 0)
        #expect(engine.cutUpTo == 0)
    }

    @Test("initialization path sets the speaker with no cut and no flush")
    func speakerInitialization() {
        var engine = CutEngine()
        #expect(engine.currentSpeaker == nil)
        #expect(push(&engine, count: 5, vadActive: true, slot: 2).isEmpty)
        #expect(engine.currentSpeaker == nil)
        #expect(push(&engine, count: 1, vadActive: true, slot: 2).isEmpty)
        #expect(engine.currentSpeaker == 2)
        #expect(engine.cutUpTo == 0)
    }

    @Test("same-record R1+R4 collision resolves via the branch test")
    func sameRecordCollision() {
        var engine = CutEngine()
        // A speaks f0–46. B dominates from f47 (crosstalk, VAD still
        // active), then VAD flips silent f50–52. At f52 R1 cuts (53) AND
        // B's dominant run reaches 6 — the branch test sees the R1 cut
        // already applied and flushes instead of attempting a midpoint cut
        // behind cutUpTo.
        _ = push(&engine, count: 47, vadActive: true, slot: 0)
        _ = push(&engine, count: 3, vadActive: true, slot: 1)
        let commands = push(&engine, count: 3, vadActive: false, slot: 1)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 53, speaker: 0, reason: .speakerChange)
            ])
        #expect(engine.currentSpeaker == 1)
    }

    @Test("stop uploads the remainder; uploads + discards tile the timeline")
    func stopTiling() {
        var engine = CutEngine()
        var uploads: [FlushCommand] = []
        uploads += push(&engine, count: 50, vadActive: true, slot: 0)
        uploads += push(&engine, count: 30, vadActive: false, slot: nil)
        uploads += push(&engine, count: 40, vadActive: true, slot: 1)
        uploads += engine.stop()
        // R1 cut 53, R3 flushed [0,53), R6 discarded [53,68), B's switch was
        // a no-op flush (boundary already behind the discard point), stop
        // shipped the rest. The only frames never uploaded are discarded
        // silence (§5.1 tiling invariant).
        #expect(
            uploads == [
                FlushCommand(startFrame: 0, endFrame: 53, speaker: 0, reason: .longSilence),
                FlushCommand(startFrame: 68, endFrame: 120, speaker: 1, reason: .stop)
            ])
        #expect(engine.flushedUpTo == 120)
        #expect(uploads.last?.reason == .stop)
    }

    @Test("all-silence session discards everything and uploads nothing")
    func allSilenceStop() {
        var engine = CutEngine()
        _ = push(&engine, count: 40, vadActive: false, slot: nil)
        // R6 trimmed to the pre-roll while running; stop discards the
        // silent remainder instead of uploading it (the pure-silence
        // hallucination case).
        #expect(engine.stop().isEmpty)
        #expect(engine.flushedUpTo == 40)
    }

    @Test("stop flushes a mixed tail but discards a fully silent one")
    func stopSilentTail() {
        var engine = CutEngine()
        // Speech then a short (sub-R3) pause: the tail still contains
        // speech, so stop uploads it, trailing silence included.
        _ = push(&engine, count: 20, vadActive: true, slot: 0)
        _ = push(&engine, count: 10, vadActive: false, slot: nil)
        let uploads = engine.stop()
        #expect(
            uploads == [
                FlushCommand(startFrame: 0, endFrame: 30, speaker: 0, reason: .stop)
            ])
    }

    // MARK: - Inspector trace (opt-in; must never change decisions)

    @Test("trace is off by default and stays empty")
    func traceOffByDefault() {
        var engine = CutEngine()
        _ = push(&engine, count: 40, vadActive: true, slot: 0)
        _ = push(&engine, count: 30, vadActive: false, slot: nil)
        _ = engine.stop()
        #expect(engine.trace.isEmpty)
    }

    @Test("trace records R1 cut, R3 flush and R6 discards with attribution")
    func traceSilenceScenario() {
        var engine = CutEngine()
        engine.traceEnabled = true
        // Speech f0–39 (speaker init at the 6th record, f5), then silence:
        // R1 cut at f42 -> cut(43), R3 flush at f64, first R6 discard to 53.
        _ = push(&engine, count: 40, vadActive: true, slot: 0)
        _ = push(&engine, count: 25, vadActive: false, slot: nil)
        let events = engine.drainTrace()
        #expect(events.first == .speakerInit(frame: 5, slot: 0))
        #expect(events.contains(.cut(frame: 43, rule: .r1)))
        #expect(
            events.contains(
                .flush(FlushCommand(startFrame: 0, endFrame: 43, speaker: 0, reason: .longSilence))
            ))
        #expect(events.contains(.discard(start: 43, end: 53)))
        #expect(engine.trace.isEmpty)  // drainTrace empties the buffer
    }

    @Test("R4 direct switch traces cut(mid, .r4), the flush, and the change")
    func traceSpeakerCutBranch() {
        var engine = CutEngine()
        engine.traceEnabled = true
        // A f0–29, B from f30 with no pause: stable at f35, mid = 30.
        _ = push(&engine, count: 30, vadActive: true, slot: 0)
        _ = push(&engine, count: 6, vadActive: true, slot: 1)
        let events = engine.drainTrace()
        #expect(events.contains(.cut(frame: 30, rule: .r4)))
        #expect(
            events.contains(
                .flush(
                    FlushCommand(startFrame: 0, endFrame: 30, speaker: 0, reason: .speakerChange))
            ))
        #expect(events.contains(.speakerChange(frame: 35, from: 0, to: 1)))
    }

    @Test("R5 forced cut is attributed .r5; stop cut .stop")
    func traceForcedAndStop() {
        var engine = CutEngine()
        engine.traceEnabled = true
        _ = push(&engine, count: 375, vadActive: true, slot: 0)
        #expect(engine.drainTrace().contains(.cut(frame: 375, rule: .r5)))
        _ = push(&engine, count: 10, vadActive: true, slot: 0)
        _ = engine.stop()
        let events = engine.drainTrace()
        #expect(events.contains(.cut(frame: 385, rule: .stop)))
        #expect(
            events.contains(
                .flush(FlushCommand(startFrame: 375, endFrame: 385, speaker: 0, reason: .stop))))
    }

    @Test("a silent stop tail traces its discard")
    func traceStopDiscard() {
        var engine = CutEngine()
        engine.traceEnabled = true
        _ = push(&engine, count: 10, vadActive: false, slot: nil)
        _ = engine.stop()
        #expect(engine.drainTrace().contains(.discard(start: 0, end: 10)))
    }

    @Test("tracing does not change decisions")
    func traceEquivalence() {
        func run(traced: Bool) -> [FlushCommand] {
            var engine = CutEngine()
            engine.traceEnabled = traced
            var commands: [FlushCommand] = []
            commands += push(&engine, count: 40, vadActive: true, slot: 0)
            commands += push(&engine, count: 30, vadActive: false, slot: nil)
            commands += push(&engine, count: 60, vadActive: true, slot: 1)
            commands += push(&engine, count: 6, vadActive: true, slot: 2)
            commands += push(&engine, count: 130, vadActive: true, slot: 2)
            commands += push(&engine, count: 4, vadActive: false, slot: nil)
            commands += engine.stop()
            return commands
        }
        #expect(run(traced: true) == run(traced: false))
    }
}
