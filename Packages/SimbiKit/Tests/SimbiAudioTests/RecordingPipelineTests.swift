import FluidAudio
import Foundation
import Testing

@testable import SimbiAudio
@testable import SimbiKit

/// Scripted diarizer: labels each session-local frame via `script`, emits
/// finalized frames in bursts of 6 like the real Sortformer (§0 fact 2),
/// with no lag (lag only delays decisions; the engine is per-frame).
final class FakeDiarizer: DiarizerStream, @unchecked Sendable {
    let script: @Sendable (Int) -> FrameLabel
    private var bufferedSamples = 0
    private var emittedFrames = 0

    init(script: @escaping @Sendable (Int) -> FrameLabel) {
        self.script = script
    }

    func prepare() async throws {}

    func resetSession() {
        bufferedSamples = 0
        emittedFrames = 0
    }

    func addAudio(_ samples: [Float]) {
        bufferedSamples += samples.count
    }

    private func predictions(for frames: Range<Int>) -> [Float] {
        var result: [Float] = []
        for frame in frames {
            var row: [Float] = [0, 0, 0, 0]
            if case .speech(let slot) = script(frame) {
                row[slot] = 1
            }
            result.append(contentsOf: row)
        }
        return result
    }

    func process() throws -> DiarizerChunkResult? {
        let available = bufferedSamples / 1280
        guard available - emittedFrames >= 6 else { return nil }
        let count = ((available - emittedFrames) / 6) * 6
        let range = emittedFrames..<(emittedFrames + count)
        emittedFrames += count
        return DiarizerChunkResult(
            startFrame: range.lowerBound,
            finalizedPredictions: predictions(for: range),
            finalizedFrameCount: count)
    }

    func finalizeSession() throws -> DiarizerChunkResult? {
        let available = bufferedSamples / 1280
        guard available > emittedFrames else { return nil }
        let range = emittedFrames..<available
        emittedFrames = available
        return DiarizerChunkResult(
            startFrame: range.lowerBound,
            finalizedPredictions: predictions(for: range),
            finalizedFrameCount: range.count)
    }
}

@Suite("RecordingPipeline", .serialized)
struct RecordingPipelineTests {
    private func makeNoteFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pipeline-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tone(frames: Int) -> [Float] {
        (0..<(frames * 1280)).map { i in
            0.4 * sin(2 * .pi * 300 * Float(i) / 16000)
        }
    }

    /// Polls until the outbox has drained into the transcript file.
    private func waitForTranscript(
        _ url: URL, entryCount: Int, timeout: TimeInterval = 5
    ) async throws -> VTTDocument {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
                let document = try? VTTParser.parse(text),
                document.entries.count >= entryCount
            {
                return document
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
        Issue.record("transcript did not reach \(entryCount) entries:\n\(text)")
        return try VTTParser.parse(text)
    }

    @Test("§12.3-shaped session: cues, gap, session notes, then resume")
    func fullSessionAndResume() async throws {
        let noteFolder = try makeNoteFolder()
        defer { try? FileManager.default.removeItem(at: noteFolder) }
        let vttURL = noteFolder.appending(path: "transcript.vtt")

        // Session shape: A speaks f0–37, silence f38–117 (6.4 s → gap),
        // A speaks f118–149.
        let diarizer = FakeDiarizer { frame in
            switch frame {
            case 0..<38: return .speech(slot: 0)
            case 38..<118: return .silence
            default: return .speech(slot: 0)
            }
        }
        let pipeline = RecordingPipeline(noteFolderURL: noteFolder, diarizer: diarizer)

        try await pipeline.start()
        // 150 frames = 12.00 s, ingested in 10-frame batches.
        let samples = tone(frames: 150)
        for batch in stride(from: 0, to: samples.count, by: 12800) {
            try await pipeline.ingest(samples: Array(samples[batch..<(batch + 12800)]))
        }
        try await pipeline.stop()

        // session start + cue + gap + cue + session end
        let document = try await waitForTranscript(vttURL, entryCount: 5)
        guard document.entries.count == 5 else { return }

        guard case .sessionStart(1, _, 0) = document.entries[0] else {
            Issue.record("expected session 1 start, got \(document.entries[0])")
            return
        }
        guard case .cue(1, 0, 3.04, "Speaker 1", _, false) = document.entries[1] else {
            Issue.record("expected cue 1 [0, 3.04], got \(document.entries[1])")
            return
        }
        guard case .gap(3.04, 9.44) = document.entries[2] else {
            Issue.record("expected gap [3.04, 9.44], got \(document.entries[2])")
            return
        }
        guard case .cue(2, 9.44, 12.0, "Speaker 1", _, false) = document.entries[3] else {
            Issue.record("expected cue 2 [9.44, 12.0], got \(document.entries[3])")
            return
        }
        guard case .sessionEnd(1, _, 12.0) = document.entries[4] else {
            Issue.record("expected session 1 end at 12.0, got \(document.entries[4])")
            return
        }

        // State and audio bookkeeping.
        let state = try NoteRecordingState.load(noteFolder: noteFolder)
        #expect(state.totalSamples == 192_000)
        #expect(state.sessionCount == 1)
        #expect(state.nextCueIndex == 3)
        #expect(state.activeSession == nil)

        let probe = try OpusWebMDecoder(fileURL: noteFolder.appending(path: "audio.webm"))
        #expect(probe.endMilliseconds == 12_000)

        // Pending files were consumed by the (stub) transcriber.
        let pending = try FileManager.default.contentsOfDirectory(
            at: noteFolder.appending(path: ".simbi/pending"), includingPropertiesForKeys: nil)
        #expect(pending.isEmpty)

        // --- Resume (§10.2): session 2 appends, numbering continues. ---
        try await pipeline.start()
        try await pipeline.ingest(samples: tone(frames: 25))  // 2 s of A
        try await pipeline.stop()

        // + session 2 start, cue 3, session 2 end
        let document2 = try await waitForTranscript(vttURL, entryCount: 8)
        guard document2.entries.count == 8 else { return }
        guard case .sessionStart(2, _, 12.0) = document2.entries[5] else {
            Issue.record("expected session 2 start at 12.0, got \(document2.entries[5])")
            return
        }
        guard case .cue(3, 12.0, 14.0, "Speaker 1", _, false) = document2.entries[6] else {
            Issue.record("expected cue 3 [12.0, 14.0], got \(document2.entries[6])")
            return
        }
        guard case .sessionEnd(2, _, 14.0) = document2.entries[7] else {
            Issue.record("expected session 2 end at 14.0, got \(document2.entries[7])")
            return
        }

        let state2 = try NoteRecordingState.load(noteFolder: noteFolder)
        #expect(state2.totalSamples == 224_000)
        #expect(state2.sessionCount == 2)

        // The appended audio.webm spans both sessions.
        let probe2 = try OpusWebMDecoder(fileURL: noteFolder.appending(path: "audio.webm"))
        #expect(probe2.endMilliseconds == 14_000)
    }

    @Test("crash recovery closes the unfinished session (§10.3)")
    func crashRecovery() async throws {
        let noteFolder = try makeNoteFolder()
        defer { try? FileManager.default.removeItem(at: noteFolder) }

        let diarizer = FakeDiarizer { _ in .speech(slot: 0) }
        let pipeline = RecordingPipeline(noteFolderURL: noteFolder, diarizer: diarizer)
        try await pipeline.start()
        try await pipeline.ingest(samples: tone(frames: 30))
        // Simulate a crash: no stop(); state.json still has activeSession.
        let crashed = try NoteRecordingState.load(noteFolder: noteFolder)
        #expect(crashed.activeSession != nil)

        // A fresh pipeline (relaunch) starts a new session; recovery runs.
        let pipeline2 = RecordingPipeline(
            noteFolderURL: noteFolder, diarizer: FakeDiarizer { _ in .speech(slot: 0) })
        try await pipeline2.start()
        try await pipeline2.ingest(samples: tone(frames: 25))
        try await pipeline2.stop()

        let recovered = try NoteRecordingState.load(noteFolder: noteFolder)
        #expect(recovered.activeSession == nil)
        #expect(recovered.sessionCount == 2)
        // Session 1's audio survived (2.4 s), session 2 appended 2 s.
        #expect(recovered.totalSamples >= 30 * 1280)

        // s1 start, s1 end (recovery), s2 start, cue 1, s2 end.
        let document = try await waitForTranscript(
            noteFolder.appending(path: "transcript.vtt"), entryCount: 5)
        // Both sessions have start and end notes.
        let sessionEnds = document.entries.filter {
            if case .sessionEnd = $0 { return true }
            return false
        }
        #expect(sessionEnds.count == 2)
    }
}
