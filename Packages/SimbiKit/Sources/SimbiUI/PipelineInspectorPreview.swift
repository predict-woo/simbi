import Foundation
import SimbiAudio

/// `SIMBI_UI_PREVIEW` driver for the Pipeline Inspector window: replays a
/// scripted ~45 s session through a **real** `CutEngine` (same rules, real
/// trace) so the window can be seen live — and screenshotted for design
/// review — without recording or audio, per the DesignSystem preview
/// convention. The script exercises R1–R4 and R6; R5 needs a 30 s
/// pause-free monologue and stays covered by unit tests.
@MainActor
final class InspectorPreviewDriver {
    /// [startFrame, endFrame) → speaker slot. 80 ms grid.
    private static let script: [(Range<Int>, Int)] = [
        (38..<90, 0),  //  3.0– 7.2 s  S1 opens
        (95..<160, 0),  //  7.6–12.8 s   micro-pause → R1 cut
        (165..<230, 0),  // 13.2–18.4 s   staging passes 10 s → R2
        (245..<310, 1),  // 19.6–24.8 s  1.2 s pause → R1, then R4 flush branch
        (310..<370, 0),  // 24.8–29.6 s  direct switch → R4 cut branch
        // 29.6–39.2 s long silence → R3 flush, R6 trimming
        (490..<540, 2),  // 39.2–43.2 s  S3 wraps up; session ends at 45 s
    ]
    private static let endFrame = 563  // 45 s
    private static let texts = [
        "Okay — the main thing today is the sidebar ordering work.",
        "The drag and drop landed last week and it changed how folders load.",
        "Quick question on that — does the sidecar survive a sync conflict?",
        "Right, that matches what I saw in testing.",
        "One note from my side: the release checklist is green.",
    ]

    private static func speaker(at frame: Int) -> Int? {
        let wrapped = frame % endFrame
        return script.first { $0.0.contains(wrapped) }?.1
    }

    /// One update per 80 ms frame, at 2× real time. Ends with a
    /// `recording: false` update (the session-ended state), then late cue
    /// texts, mirroring the real pipeline's post-stop behavior.
    func stream() -> AsyncStream<InspectorUpdate> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                var engine = CutEngine()
                engine.traceEnabled = true
                var nextCue = 0
                var pending: [(cue: Int, doneAtFrame: Int)] = []
                for frame in 0..<Self.endFrame {
                    guard !Task.isCancelled else { return }
                    let slot = Self.speaker(at: frame)
                    var probabilities: [Float] = [0.05, 0.08, 0.04, 0.06]
                    if let slot { probabilities[slot] = 0.9 }
                    _ = engine.push(vadActive: slot != nil, probabilities: probabilities[...])

                    var uploadEvents: [InspectorUploadEvent] = []
                    for event in engine.trace where isFlush(event) {
                        if case .flush(let command) = event {
                            uploadEvents.append(
                                .queued(
                                    cue: nextCue, startFrame: command.startFrame,
                                    endFrame: command.endFrame, speaker: command.speaker,
                                    reason: command.reason))
                            pending.append((nextCue, frame + 20))
                            nextCue += 1
                        }
                    }
                    while let first = pending.first, first.doneAtFrame <= frame {
                        pending.removeFirst()
                        uploadEvents.append(
                            .finished(
                                cue: first.cue,
                                text: Self.texts[first.cue % Self.texts.count]))
                    }
                    continuation.yield(
                        update(
                            engine: &engine,
                            tick: Tick(
                                frame: frame, recording: true, slot: slot,
                                probabilities: probabilities),
                            uploadEvents: uploadEvents, inFlight: pending.count))
                    try? await Task.sleep(for: .milliseconds(40))
                }
                // Stop: final cut/flush, then the late transcriptions.
                var stopEvents: [InspectorUploadEvent] = []
                for command in engine.stop() {
                    stopEvents.append(
                        .queued(
                            cue: nextCue, startFrame: command.startFrame,
                            endFrame: command.endFrame, speaker: command.speaker,
                            reason: command.reason))
                    pending.append((nextCue, 0))
                    nextCue += 1
                }
                continuation.yield(
                    update(
                        engine: &engine,
                        tick: Tick(
                            frame: Self.endFrame, recording: false, slot: nil,
                            probabilities: [0, 0, 0, 0]),
                        uploadEvents: stopEvents, inFlight: pending.count))
                for (index, entry) in pending.enumerated() {
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled else { return }
                    continuation.yield(
                        update(
                            engine: &engine,
                            tick: Tick(
                                frame: Self.endFrame, recording: false, slot: nil,
                                probabilities: [0, 0, 0, 0]),
                            uploadEvents: [
                                .finished(
                                    cue: entry.cue,
                                    text: Self.texts[entry.cue % Self.texts.count])
                            ],
                            inFlight: pending.count - index - 1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func isFlush(_ event: CutEvent) -> Bool {
        if case .flush = event { return true }
        return false
    }

    /// One scripted frame's worth of snapshot inputs.
    private struct Tick {
        var frame: Int
        var recording: Bool
        var slot: Int?
        var probabilities: [Float]
    }

    private func update(
        engine: inout CutEngine, tick: Tick,
        uploadEvents: [InspectorUploadEvent], inFlight: Int
    ) -> InspectorUpdate {
        let samplesFed =
            (tick.frame + CutConstants.pipelineLatencyFrames) * CutConstants.frameSamples
        let records =
            tick.recording
            ? [
                InspectorFrameRecord(
                    frame: tick.frame, vadActive: tick.slot != nil, dominantSlot: tick.slot,
                    probabilities: tick.probabilities)
            ] : []
        return InspectorUpdate(
            recording: tick.recording,
            samplesFed: samplesFed,
            sessionBaseSeconds: 0,
            vadChunks: samplesFed / CutConstants.vadChunkSamples,
            sortFramesFinalized: engine.frontier + 6,
            frontier: engine.frontier,
            cutUpTo: engine.cutUpTo,
            flushedUpTo: engine.flushedUpTo,
            silenceRun: engine.silenceRun,
            dominantRun: engine.dominantRun,
            previousDominant: engine.previousDominant,
            currentSpeaker: engine.currentSpeaker,
            uploadQueueDepth: 0,
            uploadsInFlight: min(2, inFlight),
            records: records,
            events: engine.drainTrace(),
            uploadEvents: uploadEvents)
    }
}
