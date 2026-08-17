import Foundation
import Testing

@testable import SimbiAudio

/// Tests for the Pipeline Inspector tap: the pure `InspectorTimelineState`
/// reducer, and the `RecordingPipeline` update stream (with the same fake
/// models as RecordingPipelineTests).

@Suite("InspectorTimelineState")
struct InspectorTimelineStateTests {
    private func update(
        records: [InspectorFrameRecord] = [],
        events: [CutEvent] = [],
        uploadEvents: [InspectorUploadEvent] = []
    ) -> InspectorUpdate {
        InspectorUpdate(
            recording: true, samplesFed: 0, sessionBaseSeconds: 0, vadChunks: 0,
            sortFramesFinalized: 0, frontier: 0, cutUpTo: 0, flushedUpTo: 0,
            silenceRun: 0, dominantRun: 0, previousDominant: nil, currentSpeaker: nil,
            uploadQueueDepth: 0, uploadsInFlight: 0,
            records: records, events: events, uploadEvents: uploadEvents)
    }

    @Test("adjacent discards merge into one span and one coalesced log entry")
    func discardCoalescing() {
        var state = InspectorTimelineState()
        state.apply(update(events: [.discard(start: 40, end: 53)]))
        state.apply(update(events: [.discard(start: 53, end: 54)]))
        state.apply(update(events: [.discard(start: 54, end: 55)]))
        #expect(state.discards == [.init(start: 40, end: 55)])
        #expect(state.log.count == 1)
        #expect(state.log[0].tag == "R6")
        #expect(state.log[0].message.contains("1.2 s"))  // 15 frames
    }

    @Test("a cut ends the trimming run; a later discard starts a new entry")
    func discardRunEndsAtCut() {
        var state = InspectorTimelineState()
        state.apply(update(events: [.discard(start: 40, end: 53)]))
        state.apply(update(events: [.cut(frame: 80, rule: .r1)]))
        state.apply(update(events: [.discard(start: 90, end: 100)]))
        #expect(state.discards == [.init(start: 40, end: 53), .init(start: 90, end: 100)])
        let r6Entries = state.log.filter { $0.tag == "R6" }
        #expect(r6Entries.count == 2)
    }

    @Test("a queued upload becomes a segment; finished fills its transcript")
    func segmentLifecycle() {
        var state = InspectorTimelineState()
        state.apply(
            update(uploadEvents: [
                .queued(cue: 7, startFrame: 0, endFrame: 43, speaker: 0, reason: .longSilence)
            ]))
        #expect(state.segments.count == 1)
        #expect(state.segments[0].id == 7)
        #expect(state.segments[0].status == .queued)
        state.apply(update(uploadEvents: [.finished(cue: 7, text: "hello there")]))
        #expect(state.segments[0].status == .done(text: "hello there"))
    }

    @Test("records from a mid-session subscribe anchor at their real frame")
    func midSessionAnchor() {
        // Opening the inspector mid-recording delivers a first record at
        // the pipeline's current frontier, not frame 0 — the lanes must
        // anchor there or everything draws shifted left.
        var state = InspectorTimelineState()
        let records = (100..<110).map {
            InspectorFrameRecord(frame: $0, vadActive: true, dominantSlot: 0)
        }
        state.apply(update(records: records))
        #expect(state.firstBufferedFrame == 100)
        #expect(state.frames.count == 10)
        #expect(state.frames.first?.frame == 100)
    }

    @Test("a gap from dropped updates is padded so alignment holds")
    func gapPadding() {
        var state = InspectorTimelineState()
        state.apply(
            update(records: [
                InspectorFrameRecord(frame: 5, vadActive: true, dominantSlot: 1)
            ]))
        state.apply(
            update(records: [
                InspectorFrameRecord(frame: 8, vadActive: true, dominantSlot: 1)
            ]))
        #expect(state.frames.count == 4)  // 5, 6 (pad), 7 (pad), 8
        #expect(state.frames.map(\.frame) == [5, 6, 7, 8])
        #expect(state.frames[1].vadActive == false)
        #expect(state.frames[1].dominantSlot == nil)
        #expect(state.frames[3].dominantSlot == 1)
    }

    @Test("a session restart resets the timeline to the new frame axis")
    func sessionRestartResets() {
        var state = InspectorTimelineState()
        state.apply(
            update(
                records: (100..<103).map {
                    InspectorFrameRecord(frame: $0, vadActive: true, dominantSlot: 0)
                },
                events: [.cut(frame: 101, rule: .r1), .discard(start: 90, end: 95)],
                uploadEvents: [
                    .queued(cue: 0, startFrame: 80, endFrame: 101, speaker: 0, reason: .stop)
                ]))
        // Stop + resume: session-local frames restart below the expected
        // next frame — the old artifacts no longer share an axis.
        state.apply(
            update(records: [
                InspectorFrameRecord(frame: 0, vadActive: false, dominantSlot: nil)
            ]))
        #expect(state.firstBufferedFrame == 0)
        #expect(state.frames.map(\.frame) == [0])
        #expect(state.segments.isEmpty)
        #expect(state.discards.isEmpty)
        #expect(state.cutMarks.isEmpty)
    }

    @Test("frame buffer is capped and tracks its first buffered frame")
    func frameCap() {
        var state = InspectorTimelineState()
        let batch = (0..<(InspectorTimelineState.maxFrames + 100)).map {
            InspectorFrameRecord(frame: $0, vadActive: true, dominantSlot: 0)
        }
        state.apply(update(records: batch))
        #expect(state.frames.count == InspectorTimelineState.maxFrames)
        #expect(state.firstBufferedFrame == 100)
        #expect(state.frames.first?.frame == 100)
    }
}

@Suite("RecordingPipeline inspector tap", .serialized)
struct PipelineInspectorTapTests {
    private func makeNoteFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "inspector-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the stream carries released records, engine events and cue text")
    func inspectorTap() async throws {
        let noteFolder = try makeNoteFolder()
        defer { try? FileManager.default.removeItem(at: noteFolder) }

        // A speaks f0–37, then silence to f117: R1 cuts at 41, R3 flushes
        // at frame 62 (silence from 38), R6 trims after. One cue.
        let diarizer = FakeDiarizer { frame in
            frame < 38 ? .speech(slot: 0) : .silence
        }
        // Chunk c covers samples [c·4096, (c+1)·4096): speech through
        // sample 38·1280 = 48640 → chunks 0–11.
        let vad = FakeVad { chunk in chunk < 12 }
        let pipeline = RecordingPipeline(
            noteFolderURL: noteFolder, transcriber: FakeTranscriber(),
            diarizer: diarizer, vad: vad)

        let stream = await pipeline.inspectorUpdates()
        try await pipeline.start()
        // 118 frames in ~12-frame batches.
        let samples = [Float](repeating: 0.1, count: 118 * 1280)
        var fed = 0
        while fed < samples.count {
            let batch = Array(samples[fed..<min(fed + 12 * 1280, samples.count)])
            try await pipeline.ingest(samples: batch)
            fed += batch.count
        }
        try await pipeline.stop()

        // The stream stays open past stop (cue text arrives late); read
        // until the first `.finished` upload event.
        var updates: [InspectorUpdate] = []
        var sawText: String?
        for await update in stream {
            updates.append(update)
            if let text = update.uploadEvents.lazy.compactMap({ event -> String? in
                if case .finished(_, let text) = event { return text }
                return nil
            }).first {
                sawText = text
                break
            }
        }
        #expect(sawText == "[fake transcription]")

        // Released records are contiguous from frame 0 and mirror the fakes.
        let records = updates.flatMap(\.records)
        #expect(records.first?.frame == 0)
        #expect(records.map(\.frame) == Array(0..<records.count))
        #expect(records[0].vadActive)
        #expect(records[0].dominantSlot == 0)
        #expect(records[50].vadActive == false)
        #expect(records[50].dominantSlot == nil)

        // Engine events made it across, attributed.
        let events = updates.flatMap(\.events)
        #expect(events.contains(.speakerInit(frame: 5, slot: 0)))
        #expect(events.contains(.cut(frame: 41, rule: .r1)))
        #expect(events.contains(where: { if case .discard = $0 { true } else { false } }))

        // Pointer snapshots are monotone and end at the engine's rest state.
        let last = updates.last!
        #expect(last.flushedUpTo <= last.cutUpTo && last.cutUpTo <= last.frontier)
        #expect(updates.map(\.frontier) == updates.map(\.frontier).sorted())
    }

    @Test("without a subscriber the pipeline records and uploads normally")
    func noSubscriberPath() async throws {
        let noteFolder = try makeNoteFolder()
        defer { try? FileManager.default.removeItem(at: noteFolder) }
        let diarizer = FakeDiarizer { frame in frame < 30 ? .speech(slot: 1) : .silence }
        let vad = FakeVad { chunk in chunk < 10 }
        let pipeline = RecordingPipeline(
            noteFolderURL: noteFolder, transcriber: FakeTranscriber(),
            diarizer: diarizer, vad: vad)
        try await pipeline.start()
        try await pipeline.ingest(samples: [Float](repeating: 0.1, count: 60 * 1280))
        try await pipeline.stop()
        // The session still produced its cue — the tap is a pure add-on.
        // (Upload + outbox render are async; poll like the pipeline suite.)
        let vttURL = noteFolder.appending(path: "transcript.vtt")
        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: vttURL, encoding: .utf8)) ?? ""
            if text.contains("Speaker 2") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(text.contains("Speaker 2"))
    }
}
