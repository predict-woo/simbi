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
        feed(&engine, S, 30, into: &actions)  // f120–149 long silence
        actions.append(contentsOf: engine.stop(realFrameEnd: 150))

        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 50, speaker: 0,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 55, endFrame: 90, speaker: 1,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 93, endFrame: 120, speaker: 0,
                        reason: .longSilence, continuation: false)),
                .gap(startFrame: 120, endFrame: 150),
            ])
    }

    @Test("§12.2 monologue crossing 10 s with an embedded 1 s pause")
    func scenario2() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 75, into: &actions)  // f0–74
        feed(&engine, S, 13, into: &actions)  // f75–87 (1.04 s)
        feed(&engine, A, 75, into: &actions)  // f88–162
        feed(&engine, S, 38, into: &actions)  // f163–200
        actions.append(contentsOf: engine.stop(realFrameEnd: 201))

        #expect(
            actions == [
                // Boundary cut at the glue|open boundary f88; trailing glue
                // [75,88) trimmed → cue ends exactly where speech stopped.
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 75, speaker: 0,
                        reason: .maxBuffer, continuation: false)),
                // Continuation marker: same speaker after a MAX_BUFFER cut.
                .flush(
                    FlushCommand(
                        startFrame: 88, endFrame: 163, speaker: 0,
                        reason: .longSilence, continuation: true)),
                .gap(startFrame: 163, endFrame: 201),
            ])
    }

    @Test("§12.2 variant: unbroken 13 s run hard-cuts at 10 s")
    func scenario2HardCut() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 163, into: &actions)  // 13.04 s unbroken
        feed(&engine, S, 30, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 193))

        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 125, speaker: 0,
                        reason: .maxBuffer, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 125, endFrame: 163, speaker: 0,
                        reason: .longSilence, continuation: true)),
                .gap(startFrame: 163, endFrame: 193),
            ])
    }

    @Test("§12.3 pause ≥ 2 s, same speaker resumes, stop with pad")
    func scenario3() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, A, 38, into: &actions)  // f0–37
        feed(&engine, S, 35, into: &actions)  // f38–72 (2.80 s)
        feed(&engine, A, 27, into: &actions)  // f73–99
        feed(&engine, S, 13, into: &actions)  // f100–112 real silence
        // Stop at 9.00 s: realFrameEnd = 113; the pipeline announces the
        // bound, then the 2 s stop-pad arrives as forced-silence frames.
        engine.beginStop(realFrameEnd: 113)
        feed(&engine, S, 25, into: &actions)  // pad frames f113–137
        actions.append(contentsOf: engine.stop(realFrameEnd: 113))

        #expect(
            actions == [
                .flush(
                    FlushCommand(
                        startFrame: 0, endFrame: 38, speaker: 0,
                        reason: .longSilence, continuation: false)),
                .gap(startFrame: 38, endFrame: 73),
                // Final silence has only 13 real frames: no gap, and the
                // trailing cue flushes via .stop, ending at real speech.
                .flush(
                    FlushCommand(
                        startFrame: 73, endFrame: 100, speaker: 0,
                        reason: .stop, continuation: false)),
            ])
    }

    // MARK: §5 edge-case table

    @Test("≤2-frame speech blip inside silence is absorbed")
    func speechBlipAbsorbed() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, S, 30, into: &actions)
        feed(&engine, B, 2, into: &actions)
        feed(&engine, S, 30, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 62))
        // One continuous silence run; single gap, no cues.
        #expect(actions == [.gap(startFrame: 0, endFrame: 62)])
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
                        startFrame: 0, endFrame: 41, speaker: 0,
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
                        startFrame: 0, endFrame: 42, speaker: 0,
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
                        startFrame: 0, endFrame: 22, speaker: 0,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 22, endFrame: 42, speaker: 2,
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
                        startFrame: 0, endFrame: 20, speaker: 0,
                        reason: .speakerSwitch, continuation: false)),
                .flush(
                    FlushCommand(
                        startFrame: 20, endFrame: 40, speaker: 1,
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
                        startFrame: 0, endFrame: 10, speaker: 0,
                        reason: .stop, continuation: false))
            ])
    }

    @Test("sub-0.25 s speech between cuts is dropped (no cue)")
    func tinySpeechDropped() {
        var engine = CutEngine()
        var actions: [CutAction] = []
        feed(&engine, S, 30, into: &actions)
        feed(&engine, A, 2, into: &actions)  // absorbed into silence
        feed(&engine, S, 30, into: &actions)
        actions.append(contentsOf: engine.stop(realFrameEnd: 62))
        #expect(actions == [.gap(startFrame: 0, endFrame: 62)])
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
        }
        // Cues are disjoint and ordered.
        let cues = actions.compactMap { action -> FlushCommand? in
            if case .flush(let cmd) = action { return cmd }
            return nil
        }
        for (a, b) in zip(cues, cues.dropFirst()) {
            #expect(a.endFrame <= b.startFrame)
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
            feed(&engine, S, 30, into: &actions)
            feed(&engine, A, 10, into: &actions)
            actions.append(contentsOf: engine.stop(realFrameEnd: 235))
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
