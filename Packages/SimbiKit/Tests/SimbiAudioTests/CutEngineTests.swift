import Testing

@testable import SimbiAudio

/// Tests the cut engine against docs/recording-algorithm.md: the §12 worked
/// scenarios frame-by-frame, the §5 edge-case table, and determinism (§13.6).
@Suite("CutEngine")
struct CutEngineTests {
    private let A = FrameLabel.speech(slot: 0)
    private let B = FrameLabel.speech(slot: 1)
    private let C = FrameLabel.speech(slot: 2)
    private let S = FrameLabel.silence

    /// Runs `count` frames of `label` through the engine, appending actions.
    private func feed(
        _ engine: inout CutEngine, _ label: FrameLabel, _ count: Int,
        into actions: inout [CutAction]
    ) {
        for _ in 0..<count {
            actions.append(contentsOf: engine.push(label: label))
        }
    }

    @Test("§12.1 two speakers alternating with short gaps")
    func scenario1() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 50, into: &actions)  // f0–49
        feed(&engine, S, 5, into: &actions)  // f50–54 (0.40 s)
        feed(&engine, B, 35, into: &actions)  // f55–89
        feed(&engine, S, 3, into: &actions)  // f90–92 (0.24 s)
        feed(&engine, A, 27, into: &actions)  // f93–119
        feed(&engine, S, 80, into: &actions)  // f120–199 long silence (6.4 s)
        actions.append(contentsOf: engine.stop(realFrameEnd: 200))

        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 50,
                        uploadStartFrame: 0, uploadEndFrame: 50, speaker: 0,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 55, endFrame: 90,
                        uploadStartFrame: 55, uploadEndFrame: 90, speaker: 1,
                        reason: .speakerSwitch, continuation: false)),
                // Long-silence flush carries the 2 s trailing upload pad
                // into the silence; the cue still ends at the speech.
                .flush(
                    FlushCommand(
                        startFrame: 93, endFrame: 120,
                        uploadStartFrame: 93, uploadEndFrame: 145, speaker: 0,
                        reason: .longSilence, continuation: false)),
                .gap(startFrame: 120, endFrame: 200),
            ])
    }

    @Test("§12.2 monologue crossing 10 s with an embedded 1 s pause")
    func scenario2() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 75, into: &actions)  // f0–74
        feed(&engine, S, 13, into: &actions)  // f75–87 (1.04 s, glued)
        feed(&engine, A, 75, into: &actions)  // f88–162
        feed(&engine, S, 80, into: &actions)  // f163–242
        actions.append(contentsOf: engine.stop(realFrameEnd: 243))

        #expect(
            actions == [
                // Boundary cut at the glue|open boundary f88; trailing glue
                // [75,88) trimmed → cue ends exactly where speech stopped.
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 75,
                        uploadStartFrame: 0, uploadEndFrame: 75, speaker: 0,
                        reason: .maxBuffer, continuation: false)),
                // Continuation marker: same speaker after a MAX_BUFFER cut.
                .flush(
                    FlushCommand(
                        startFrame: 88, endFrame: 163,
                        uploadStartFrame: 88, uploadEndFrame: 188, speaker: 0,
                        reason: .longSilence, continuation: true)),
                .gap(startFrame: 163, endFrame: 243),
            ])
    }

    @Test("§12.2 variant: unbroken 13 s run hard-cuts at 10 s")
    func scenario2HardCut() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 163, into: &actions)  // 13.04 s unbroken
        feed(&engine, S, 80, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 243))

        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 125,
                        uploadStartFrame: 0, uploadEndFrame: 125, speaker: 0,
                        reason: .maxBuffer, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 125, endFrame: 163,
                        uploadStartFrame: 125, uploadEndFrame: 188, speaker: 0,
                        reason: .longSilence, continuation: true)),
                .gap(startFrame: 163, endFrame: 243),
            ])
    }

    @Test("§12.3 pause > 6 s: pads on both gap edges, stop with pad")
    func scenario3() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 38, into: &actions)  // f0–37
        feed(&engine, S, 80, into: &actions)  // f38–117 (6.4 s)
        feed(&engine, A, 27, into: &actions)  // f118–144
        feed(&engine, S, 13, into: &actions)  // f145–157 real silence
        // Stop at 12.64 s: realFrameEnd = 158; the pipeline announces the
        // bound, then the 2 s stop-pad arrives as forced-silence frames.
        engine.beginStop(realFrameEnd: 158)
        feed(&engine, S, 25, into: &actions)  // pad frames f158–182
        actions.append(contentsOf: engine.stop(realFrameEnd: 158))

        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 38,
                        uploadStartFrame: 0, uploadEndFrame: 63, speaker: 0,
                        reason: .longSilence, continuation: false)),
                .gap(startFrame: 38, endFrame: 118),
                // The resumed segment's upload starts 2 s into the gap's
                // tail (leading pad); its cue still starts at the speech.
                // Final silence has only 13 real frames: no gap, trailing
                // silence trimmed from both cue and upload at .stop.
                .flush(
                    FlushCommand(
                        startFrame: 118, endFrame: 145,
                        uploadStartFrame: 93, uploadEndFrame: 145, speaker: 0,
                        reason: .stop, continuation: false)),
            ])
    }

    @Test("silence ≤ 6 s between same-speaker speech glues into one cue")
    func mediumSilenceGlues() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 20, into: &actions)  // f0–19
        feed(&engine, S, 60, into: &actions)  // f20–79 (4.8 s — glued now)
        feed(&engine, A, 20, into: &actions)  // f80–99
        actions.append(contentsOf: engine.stop(realFrameEnd: 100))
        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 100,
                        uploadStartFrame: 0, uploadEndFrame: 100, speaker: 0,
                        reason: .stop, continuation: false))
            ])
    }

    @Test("silence ≤ 6 s before a different speaker is dropped, no gap")
    func mediumSilenceAcrossSwitch() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 20, into: &actions)  // f0–19
        feed(&engine, S, 60, into: &actions)  // f20–79
        feed(&engine, B, 20, into: &actions)  // f80–99
        actions.append(contentsOf: engine.stop(realFrameEnd: 100))
        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 20,
                        uploadStartFrame: 0, uploadEndFrame: 20, speaker: 0,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 80, endFrame: 100,
                        uploadStartFrame: 80, uploadEndFrame: 100, speaker: 1,
                        reason: .stop, continuation: false)),
            ])
    }

    // MARK: §5 edge-case table

    @Test("≤2-frame speech blip inside silence is absorbed")
    func speechBlipAbsorbed() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, S, 40, into: &actions)
        feed(&engine, B, 2, into: &actions)
        feed(&engine, S, 40, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 82))
        // One continuous silence run; single gap, no cues.
        #expect(actions == [.gap(startFrame: 0, endFrame: 82)])
    }

    @Test("1-frame silence inside speech is absorbed into one run")
    func silenceBlipAbsorbed() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 20, into: &actions)
        feed(&engine, S, 1, into: &actions)
        feed(&engine, A, 20, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 41))
        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 41,
                        uploadStartFrame: 0, uploadEndFrame: 41, speaker: 0,
                        reason: .stop, continuation: false))
            ])
    }

    @Test("A → B(2 frames) → A merges into one A run")
    func flickerMerges() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 20, into: &actions)
        feed(&engine, B, 2, into: &actions)
        feed(&engine, A, 20, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 42))
        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 42,
                        uploadStartFrame: 0, uploadEndFrame: 42, speaker: 0,
                        reason: .stop, continuation: false))
            ])
    }

    @Test("A → B(2 frames) → C: blip absorbed into A, then A→C switch")
    func blipBeforeThirdSpeaker() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 20, into: &actions)  // f0–19
        feed(&engine, B, 2, into: &actions)  // f20–21 absorbed into A
        feed(&engine, C, 20, into: &actions)  // f22–41
        actions.append(contentsOf: engine.stop(realFrameEnd: 42))
        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 22,
                        uploadStartFrame: 0, uploadEndFrame: 22, speaker: 0,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 22, endFrame: 42,
                        uploadStartFrame: 22, uploadEndFrame: 42, speaker: 2,
                        reason: .stop, continuation: false)),
            ])
    }

    @Test("direct A→B switch with no silence cuts at the boundary frame")
    func directSwitch() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 20, into: &actions)
        feed(&engine, B, 20, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 40))
        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 20,
                        uploadStartFrame: 0, uploadEndFrame: 20, speaker: 0,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 20, endFrame: 40,
                        uploadStartFrame: 20, uploadEndFrame: 40, speaker: 1,
                        reason: .stop, continuation: false)),
            ])
    }

    @Test("speech starting at frame 0 stands (virtual silence predecessor)")
    func speechAtZero() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 10, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 10))
        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 10,
                        uploadStartFrame: 0, uploadEndFrame: 10, speaker: 0,
                        reason: .stop, continuation: false))
            ])
    }

    @Test("sub-0.25 s speech between cuts is dropped (no cue)")
    func tinySpeechDropped() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, S, 40, into: &actions)
        feed(&engine, A, 2, into: &actions)  // absorbed into silence
        feed(&engine, S, 40, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 82))
        #expect(actions == [.gap(startFrame: 0, endFrame: 82)])
    }

    // MARK: invariants

    @Test("no cue exceeds MAX_BUFFER + burst overshoot (§13.2)")
    func cueLengthBound() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        // Adversarial: 60 s alternating long monologues and glued pauses.
        for block in 0..<5 {
            feed(&engine, .speech(slot: block % 2), 130, into: &actions)
            feed(&engine, S, 10, into: &actions)
            feed(&engine, .speech(slot: block % 2), 10, into: &actions)
        }
        actions.append(contentsOf: engine.stop(realFrameEnd: 750))
        for case .flush(let cmd) in actions {
            #expect(cmd.endFrame - cmd.startFrame <= CutConstants.maxBufferFrames + 5)
            #expect(cmd.endFrame > cmd.startFrame)
            // Upload extents contain the cue extents, padded by ≤ 2 s.
            #expect(cmd.uploadStartFrame <= cmd.startFrame)
            #expect(cmd.startFrame - cmd.uploadStartFrame <= CutConstants.silencePadFrames)
            #expect(cmd.uploadEndFrame >= cmd.endFrame)
            #expect(cmd.uploadEndFrame - cmd.endFrame <= CutConstants.silencePadFrames)
        }
        // Cues are disjoint and ordered; so are their padded uploads (the
        // pads meet inside a ≥ 6 s gap, 2 s from each side).
        let cues = actions.compactMap { action -> FlushCommand? in
            if case .flush(let cmd) = action { return cmd }
            return nil
        }
        for (a, b) in zip(cues, cues.dropFirst()) {
            #expect(a.endFrame <= b.startFrame)
            #expect(a.uploadEndFrame <= b.uploadStartFrame)
        }
    }

    @Test("replaying the same stream is byte-identical (§13.6)")
    func deterministic() {
        func run() -> [CutAction] {
            var engine = CutEngine()
            var actions: [CutAction] = []
            feed(&engine, A, 50, into: &actions)
            feed(&engine, S, 5, into: &actions)
            feed(&engine, B, 140, into: &actions)
            feed(&engine, S, 80, into: &actions)
            feed(&engine, A, 10, into: &actions)
            actions.append(contentsOf: engine.stop(realFrameEnd: 285))
            return actions
        }
        #expect(run() == run())
    }

    @Test("frame labeling: argmax over active slots, tie → lowest")
    func labeling() {
        #expect(labelFrame(probabilities: [0.1, 0.2, 0.3, 0.4][...]) == .silence)
        #expect(labelFrame(probabilities: [0.6, 0.2, 0.1, 0.1][...]) == .speech(slot: 0))
        #expect(labelFrame(probabilities: [0.5, 0.9, 0.1, 0.1][...]) == .speech(slot: 1))
        #expect(labelFrame(probabilities: [0.7, 0.7, 0.1, 0.1][...]) == .speech(slot: 0))
        #expect(labelFrame(probabilities: [0.4999, 0.1, 0.1, 0.5][...]) == .speech(slot: 3))
    }
}
