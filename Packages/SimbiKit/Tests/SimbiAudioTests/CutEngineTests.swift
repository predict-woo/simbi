import Testing

@testable import SimbiAudio

/// Unit tests for the v2 cuts-and-flushes engine (guide §5), ported from the
/// scenarios of docs/recording-algorithm-sim.py. Records are synthesized
/// directly — the engine is a pure function of the record stream.
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

    @Test("R1 cuts at 3 silent records, R3 flushes at 25")
    func silenceCutAndLongSilenceFlush() {
        var engine = CutEngine()
        // Speech f0–39, then silence.
        #expect(push(&engine, count: 40, vadActive: true, slot: 0).isEmpty)
        // Silence f40–63: R1 fires at f42 -> cut(43); R3 fires at f64.
        #expect(push(&engine, count: 24, vadActive: false, slot: nil).isEmpty)
        #expect(engine.cutUpTo == 43)
        let commands = push(&engine, count: 1, vadActive: false, slot: nil)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 43, speaker: 0, reason: .longSilence)
            ])
        // Silence continuing past 25 frames never re-fires (edge trigger).
        #expect(push(&engine, count: 50, vadActive: false, slot: nil).isEmpty)
    }

    @Test("leading silence never cuts and never uploads alone")
    func leadingSilenceGuard() {
        var engine = CutEngine()
        // A silence run starting at frame 0: R1's guard blocks the cut, and
        // R3's flush is a no-op on empty staging.
        #expect(push(&engine, count: 60, vadActive: false, slot: nil).isEmpty)
        #expect(engine.cutUpTo == 0)
        // Speech f60–79, then a pause: R1 cuts at f82 -> cut(83), and the
        // first upload includes the leading silence (tiling invariant —
        // nothing is ever discarded).
        #expect(push(&engine, count: 20, vadActive: true, slot: 1).isEmpty)
        let commands = push(&engine, count: 25, vadActive: false, slot: nil)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 83, speaker: 1, reason: .longSilence)
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

    @Test("R4 branch 1: VAD already cut the boundary -> flush only")
    func speakerChangeAfterPause() {
        var engine = CutEngine()
        // A f0–49; silence f50–59 (R1 cut at 53); B from f60.
        _ = push(&engine, count: 50, vadActive: true, slot: 0)
        _ = push(&engine, count: 10, vadActive: false, slot: nil)
        #expect(engine.cutUpTo == 53)
        // B stable at its 3rd record (f62): lastStop(A)=49, 49-3 < 53.
        var commands = push(&engine, count: 2, vadActive: true, slot: 1)
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
        // A f0–49, B f50– with no silence: stable at f52,
        // midpoint (49+1+50)/2 = 50.
        _ = push(&engine, count: 50, vadActive: true, slot: 0)
        let commands = push(&engine, count: 3, vadActive: true, slot: 1)
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
        // 2 frames of B (< speakerStableFrames), then A again.
        #expect(push(&engine, count: 2, vadActive: true, slot: 1).isEmpty)
        #expect(push(&engine, count: 30, vadActive: true, slot: 0).isEmpty)
        #expect(engine.currentSpeaker == 0)
        #expect(engine.cutUpTo == 0)
    }

    @Test("initialization path sets the speaker with no cut and no flush")
    func speakerInitialization() {
        var engine = CutEngine()
        #expect(engine.currentSpeaker == nil)
        #expect(push(&engine, count: 3, vadActive: true, slot: 2).isEmpty)
        #expect(engine.currentSpeaker == 2)
        #expect(engine.cutUpTo == 0)
    }

    @Test("same-record R1+R4 collision resolves via the branch test")
    func sameRecordCollision() {
        var engine = CutEngine()
        // A speaks f0–49. Then records that are VAD-silent while Sortformer
        // hears B (crosstalk): at f52 R1 cuts (53) AND B turns stable — the
        // branch test sees the R1 cut already applied and flushes instead
        // of attempting a midpoint cut behind cutUpTo.
        _ = push(&engine, count: 50, vadActive: true, slot: 0)
        _ = push(&engine, count: 2, vadActive: false, slot: 1)
        let commands = push(&engine, count: 1, vadActive: false, slot: 1)
        #expect(
            commands == [
                FlushCommand(startFrame: 0, endFrame: 53, speaker: 0, reason: .speakerChange)
            ])
        #expect(engine.currentSpeaker == 1)
    }

    @Test("stop uploads the remainder; uploads tile the timeline")
    func stopTiling() {
        var engine = CutEngine()
        var uploads: [FlushCommand] = []
        uploads += push(&engine, count: 50, vadActive: true, slot: 0)
        uploads += push(&engine, count: 30, vadActive: false, slot: nil)
        uploads += push(&engine, count: 40, vadActive: true, slot: 1)
        uploads += engine.stop()
        // Tiling invariant (§5.1): uploads partition [0, frontier).
        var position = 0
        for upload in uploads {
            #expect(upload.startFrame == position)
            #expect(upload.endFrame > upload.startFrame)
            position = upload.endFrame
        }
        #expect(position == 120)
        #expect(uploads.last?.reason == .stop)
    }

    @Test("all-silence session stops cleanly with one unlabeled upload")
    func allSilenceStop() {
        var engine = CutEngine()
        _ = push(&engine, count: 40, vadActive: false, slot: nil)
        let uploads = engine.stop()
        #expect(
            uploads == [
                FlushCommand(startFrame: 0, endFrame: 40, speaker: nil, reason: .stop)
            ])
    }
}
