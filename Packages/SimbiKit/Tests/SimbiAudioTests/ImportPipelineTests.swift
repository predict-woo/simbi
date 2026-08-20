import CodexKit
import Foundation
import Testing

@testable import SimbiAudio
@testable import SimbiKit

private struct FakeDecoder: MediaDecoding {
    let batches: [[Float]]
    let thenThrow: Bool
    func decode(url: URL) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            for batch in batches { continuation.yield(batch) }
            if thenThrow {
                continuation.finish(throwing: MediaFileDecoderError.unreadable)
            } else {
                continuation.finish()
            }
        }
    }
}

private struct FakeAnalyzer: OfflineAnalyzing {
    let records: [ImportFrameRecord]
    func prepare() async throws {}
    func analyze(_ samples: [Float]) async throws -> [ImportFrameRecord] { records }
}

private struct ThrowingPrepareAnalyzer: OfflineAnalyzing {
    struct PrepareFailed: Error {}
    func prepare() async throws { throw PrepareFailed() }
    func analyze(_ samples: [Float]) async throws -> [ImportFrameRecord] { [] }
}

private struct StubTranscriber: Transcriber {
    func transcribe(webmFile: URL) async throws -> String { "[import test]" }
}

private func makeNote() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "# note\n".write(to: url.appending(path: "note.md"), atomically: true, encoding: .utf8)
    return url
}

/// Quiet noise (constant tone would be fine too — never played).
private func pcm(seconds: Int) -> [Float] {
    (0..<(seconds * 16000)).map { _ in Float.random(in: -0.05...0.05) }
}

private actor UploadLog {
    var inFlight = 0
    var maxInFlight = 0
    var served: [Int] = []
    func begin(_ cue: Int) {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }
    func end(_ cue: Int) {
        inFlight -= 1
        served.append(cue)
    }
}

private struct CountingTranscriber: Transcriber {
    let log: UploadLog
    let failCues: Set<Int>
    func transcribe(webmFile: URL) async throws -> String {
        let cue = Int(webmFile.deletingPathExtension().lastPathComponent) ?? -1
        await log.begin(cue)
        try? await Task.sleep(for: .milliseconds(50))
        await log.end(cue)
        if failCues.contains(cue) {
            throw TranscriptionClient.TranscriptionError.requestFailed("test")
        }
        return "text for cue \(cue)"
    }
}

@Suite("ImportPipeline phase 1")
struct ImportPipelinePhase1Tests {

    @Test("phase 1 appends audio, commits totals, then completes")
    func phase1HappyPath() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        let audio = pcm(seconds: 10)
        let records = (0..<125).map { _ in ImportFrameRecord(vadActive: true, dominantSlot: 1) }
        let pipeline = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [audio], thenThrow: false),
            analyzer: FakeAnalyzer(records: records))
        try await pipeline.run(fileName: "clip.wav")
        let state = try NoteRecordingState.load(noteFolder: note)
        #expect(state.totalSamples == audio.count)
        #expect(state.sessionCount == 1)
        #expect(state.activeImport == nil)
        let probe = try OpusWebMDecoder(fileURL: NoteLayout.audioURL(noteFolder: note))
        #expect(abs(Int(probe.endMilliseconds) - 10_000) <= 40)
    }

    @Test("a decode failure rolls the note back to exactly its prior state")
    func decodeFailureRollsBack() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        // First a successful import establishes prior audio...
        let first = pcm(seconds: 5)
        let records = (0..<63).map { _ in ImportFrameRecord(vadActive: true, dominantSlot: 0) }
        let ok = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [first], thenThrow: false),
            analyzer: FakeAnalyzer(records: records))
        try await ok.run(fileName: "first.wav")
        let baselineMs = try OpusWebMDecoder(fileURL: NoteLayout.audioURL(noteFolder: note))
            .endMilliseconds
        let baselineState = try NoteRecordingState.load(noteFolder: note)
        // ...then an import that dies mid-decode.
        let bad = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [pcm(seconds: 3)], thenThrow: true),
            analyzer: FakeAnalyzer(records: []))
        await #expect(throws: (any Error).self) {
            try await bad.run(fileName: "second.wav")
        }
        let after = try NoteRecordingState.load(noteFolder: note)
        #expect(after.totalSamples == baselineState.totalSamples)
        #expect(after.activeImport == nil)
        #expect(after.imports["second.wav"]?.status == .failed)
        let afterMs = try OpusWebMDecoder(fileURL: NoteLayout.audioURL(noteFolder: note))
            .endMilliseconds
        #expect(afterMs == baselineMs)
    }

    @Test("a failed first-ever import leaves no audio.webm behind")
    func firstImportFailureRemovesFile() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        let bad = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [pcm(seconds: 2)], thenThrow: true),
            analyzer: FakeAnalyzer(records: []))
        await #expect(throws: (any Error).self) { try await bad.run(fileName: "clip.wav") }
        #expect(!FileManager.default.fileExists(atPath: NoteLayout.audioURL(noteFolder: note).path))
    }

    @Test("rollbackStalePhase1 truncates a crashed import's audio")
    func staleMarkerRollback() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        // Simulate: prior 5 s of audio committed, then a crash mid-import
        // after appending 3 more seconds with the marker still at phase 1.
        let audioURL = NoteLayout.audioURL(noteFolder: note)
        let enc1 = try OpusWebMEncoder(fileURL: audioURL, mode: .create)
        try enc1.append(samples: pcm(seconds: 5))
        try enc1.finish()
        try NoteRecordingState.update(noteFolder: note) {
            $0.totalSamples = 5 * 16000
            $0.sessionCount = 1
            $0.activeImport = .init(
                fileName: "crash.mp4", n: 2, baseSamples: 5 * 16000, phase: 1, audioTouched: true)
            $0.imports["crash.mp4"] = .init(status: .analyzing)
        }
        let enc2 = try OpusWebMEncoder(fileURL: audioURL, mode: .append(baseMilliseconds: 5000))
        try enc2.append(samples: pcm(seconds: 3))
        try enc2.finish()
        try ImportPipeline.rollbackStalePhase1(noteFolder: note)
        let state = try NoteRecordingState.load(noteFolder: note)
        #expect(state.activeImport == nil)
        #expect(state.imports["crash.mp4"]?.status == .failed)
        #expect(state.totalSamples == 5 * 16000)
        let probe = try OpusWebMDecoder(fileURL: audioURL)
        #expect(abs(Int(probe.endMilliseconds) - 5000) <= 40)
    }

    @Test("import refuses while a crashed live session awaits recovery")
    func recordingRecoveryPending() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        // A live recording crashed mid-first-session: audio.webm holds the
        // session's real audio, but totals were never advanced and
        // activeSession is stale. An import must refuse outright — its
        // rollback would otherwise truncate the unrecovered audio.
        let audioURL = NoteLayout.audioURL(noteFolder: note)
        let enc = try OpusWebMEncoder(fileURL: audioURL, mode: .create)
        try enc.append(samples: pcm(seconds: 5))
        try enc.finish()
        try NoteRecordingState.update(noteFolder: note) {
            $0.totalSamples = 0
            $0.sessionCount = 0
            $0.activeSession = .init(n: 1, baseSamples: 0, wallStart: .now)
        }
        let bytesBefore = try Data(contentsOf: audioURL)
        let pipeline = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [pcm(seconds: 2)], thenThrow: false),
            analyzer: FakeAnalyzer(records: []))
        await #expect(throws: ImportPipelineError.recordingRecoveryPending) {
            try await pipeline.run(fileName: "clip.wav")
        }
        #expect(try Data(contentsOf: audioURL) == bytesBefore)
        let state = try NoteRecordingState.load(noteFolder: note)
        #expect(state.activeSession != nil)
        #expect(state.activeImport == nil)
        #expect(state.imports["clip.wav"]?.status == .failed)
    }

    @Test("a prepare failure still records the file as failed")
    func prepareFailureRecordsFailed() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        let pipeline = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [pcm(seconds: 1)], thenThrow: false),
            analyzer: ThrowingPrepareAnalyzer())
        await #expect(throws: (any Error).self) {
            try await pipeline.run(fileName: "clip.wav")
        }
        let state = try NoteRecordingState.load(noteFolder: note)
        #expect(state.imports["clip.wav"]?.status == .failed)
        #expect(state.activeImport == nil)
        #expect(!FileManager.default.fileExists(atPath: NoteLayout.audioURL(noteFolder: note).path))
    }

    @Test("an empty decode throws noAudio and rolls back")
    func emptyDecode() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        let pipeline = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [], thenThrow: false),
            analyzer: FakeAnalyzer(records: []))
        await #expect(throws: ImportPipelineError.noAudio) {
            try await pipeline.run(fileName: "empty.wav")
        }
        #expect(try NoteRecordingState.load(noteFolder: note).activeImport == nil)
    }
}

@Suite("ImportPipeline phase 2")
struct ImportPipelinePhase2Tests {
    /// Records for: speech s0 (500 frames), 30-frame silence, speech s1
    /// (500 frames) → two blocks and one gap.
    private var twoSpeakerRecords: [ImportFrameRecord] {
        Array(repeating: ImportFrameRecord(vadActive: true, dominantSlot: 0), count: 500)
            + Array(repeating: ImportFrameRecord(vadActive: false, dominantSlot: nil), count: 30)
            + Array(repeating: ImportFrameRecord(vadActive: true, dominantSlot: 1), count: 500)
    }

    @Test("a full import renders session notes, gap, and cues in order")
    func endToEnd() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        let audio = pcm(seconds: Int(Double(1030) * 0.08) + 1)  // covers 1030 frames
        let log = UploadLog()
        let pipeline = ImportPipeline(
            noteFolderURL: note,
            transcriber: CountingTranscriber(log: log, failCues: []),
            decoder: FakeDecoder(batches: [audio], thenThrow: false),
            analyzer: FakeAnalyzer(records: twoSpeakerRecords))
        try await pipeline.run(fileName: "meeting.m4a")

        let text = try String(
            contentsOf: VTT.fileURL(noteFolder: note), encoding: .utf8)
        let document = try VTTParser.parse(text)
        var cues: [(Int, Double, Double, String)] = []
        var gaps = 0
        var sessionStarts = 0
        var sessionEnds = 0
        for entry in document.entries {
            switch entry {
            case .cue(let index, let start, let end, let speaker, let cueText, _):
                cues.append((index, start, end, speaker))
                #expect(cueText.hasPrefix("text for cue"))
            case .gap: gaps += 1
            case .sessionStart: sessionStarts += 1
            case .sessionEnd: sessionEnds += 1
            }
        }
        #expect(sessionStarts == 1 && sessionEnds == 1)
        #expect(gaps == 1)
        #expect(cues.count == 2)
        #expect(cues.map(\.0) == [1, 2])
        #expect(cues[0].3 != cues[1].3)  // two speaker labels
        for (a, b) in zip(cues, cues.dropFirst()) { #expect(a.2 <= b.1) }
        // pending/ drained, state closed out.
        let pending = try? FileManager.default.contentsOfDirectory(
            atPath: NoteLayout.pendingDirURL(noteFolder: note).path)
        #expect((pending ?? []).isEmpty)
        let state = try NoteRecordingState.load(noteFolder: note)
        #expect(state.activeImport == nil)
        #expect(state.imports["meeting.m4a"]?.status == .done)
        #expect(state.nextCueIndex == 3)
    }

    @Test("uploads run at concurrency 5")
    func concurrency() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        // 12 one-speaker blocks: speech separated by 30-frame silences.
        var records: [ImportFrameRecord] = []
        for _ in 0..<12 {
            records += Array(
                repeating: ImportFrameRecord(vadActive: true, dominantSlot: 0), count: 100)
            records += Array(
                repeating: ImportFrameRecord(vadActive: false, dominantSlot: nil), count: 30)
        }
        let audio = pcm(seconds: Int(Double(records.count) * 0.08) + 1)
        let log = UploadLog()
        let pipeline = ImportPipeline(
            noteFolderURL: note,
            transcriber: CountingTranscriber(log: log, failCues: []),
            decoder: FakeDecoder(batches: [audio], thenThrow: false),
            analyzer: FakeAnalyzer(records: records))
        try await pipeline.run(fileName: "long.m4a")
        #expect(await log.maxInFlight <= ImportConstants.uploadMaxConcurrent)
        #expect(await log.maxInFlight > 1)
    }

    @Test("a terminally failed block renders [inaudible] and moves to failed/")
    func terminalFailure() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        let audio = pcm(seconds: Int(Double(1030) * 0.08) + 1)
        let log = UploadLog()
        let pipeline = ImportPipeline(
            noteFolderURL: note,
            transcriber: CountingTranscriber(log: log, failCues: [1]),
            decoder: FakeDecoder(batches: [audio], thenThrow: false),
            analyzer: FakeAnalyzer(records: twoSpeakerRecords))
        try await pipeline.run(fileName: "meeting.m4a")
        let text = try String(contentsOf: VTT.fileURL(noteFolder: note), encoding: .utf8)
        #expect(text.contains("[inaudible]"))
        let failed = try FileManager.default.contentsOfDirectory(
            atPath: NoteLayout.failedDirURL(noteFolder: note).path)
        #expect(failed.contains("1.webm") && failed.contains("1.json"))
        // Import still completes; the timeline stays whole.
        #expect(
            try NoteRecordingState.load(noteFolder: note).imports["meeting.m4a"]?.status == .done)
    }

    @Test("resumePhase2 drains pending segments left by a crash")
    func resume() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        // Simulate a phase-2 crash: audio + state committed, one pending
        // segment on disk, marker at phase 2, nothing in the VTT yet.
        let audio = pcm(seconds: 10)
        let enc = try OpusWebMEncoder(
            fileURL: NoteLayout.audioURL(noteFolder: note), mode: .create)
        try enc.append(samples: audio)
        try enc.finish()
        let pendingDir = NoteLayout.pendingDirURL(noteFolder: note)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let seg = try OpusWebMEncoder(
            fileURL: pendingDir.appending(path: "1.webm"), mode: .create)
        try seg.append(samples: Array(audio.prefix(5 * 16000)))
        try seg.finish()
        let sidecar = PendingSegment(
            cueIndex: 1, startSec: 0, endSec: 5, speaker: 0, continuation: false)
        try PersistedJSON.encoder().encode(sidecar)
            .write(to: pendingDir.appending(path: "1.json"), options: .atomic)
        try NoteRecordingState.update(noteFolder: note) {
            $0.totalSamples = audio.count
            $0.sessionCount = 1
            $0.nextCueIndex = 2
            $0.activeImport = .init(fileName: "crash.m4a", n: 1, baseSamples: 0, phase: 2)
            $0.imports["crash.m4a"] = .init(status: .transcribing)
        }
        let log = UploadLog()
        let pipeline = ImportPipeline(
            noteFolderURL: note,
            transcriber: CountingTranscriber(log: log, failCues: []),
            decoder: FakeDecoder(batches: [], thenThrow: false),
            analyzer: FakeAnalyzer(records: []))
        try await pipeline.resumePhase2()
        let text = try String(contentsOf: VTT.fileURL(noteFolder: note), encoding: .utf8)
        #expect(text.contains("text for cue 1"))
        let state = try NoteRecordingState.load(noteFolder: note)
        #expect(state.activeImport == nil)
        #expect(state.imports["crash.m4a"]?.status == .done)
    }

    @Test("run refuses over a leftover phase-2 marker until it is drained")
    func runRefusesOverLeftoverPhase2Marker() async throws {
        let note = try makeNote()
        defer { try? FileManager.default.removeItem(at: note) }
        // Same leftover as the resume test: audio + state committed, one
        // pending segment on disk, marker at phase 2. A new run() must not
        // overwrite the marker — that would orphan the pending sidecars
        // into a future live session.
        let audio = pcm(seconds: 10)
        let enc = try OpusWebMEncoder(
            fileURL: NoteLayout.audioURL(noteFolder: note), mode: .create)
        try enc.append(samples: audio)
        try enc.finish()
        let pendingDir = NoteLayout.pendingDirURL(noteFolder: note)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let seg = try OpusWebMEncoder(
            fileURL: pendingDir.appending(path: "1.webm"), mode: .create)
        try seg.append(samples: Array(audio.prefix(5 * 16000)))
        try seg.finish()
        let sidecar = PendingSegment(
            cueIndex: 1, startSec: 0, endSec: 5, speaker: 0, continuation: false)
        try PersistedJSON.encoder().encode(sidecar)
            .write(to: pendingDir.appending(path: "1.json"), options: .atomic)
        try NoteRecordingState.update(noteFolder: note) {
            $0.totalSamples = audio.count
            $0.sessionCount = 1
            $0.nextCueIndex = 2
            $0.activeImport = .init(fileName: "crash.m4a", n: 1, baseSamples: 0, phase: 2)
            $0.imports["crash.m4a"] = .init(status: .transcribing)
        }
        let pipeline = ImportPipeline(
            noteFolderURL: note, transcriber: StubTranscriber(),
            decoder: FakeDecoder(batches: [pcm(seconds: 2)], thenThrow: false),
            analyzer: FakeAnalyzer(records: []))
        await #expect(throws: ImportPipelineError.resumePending) {
            try await pipeline.run(fileName: "other.wav")
        }
        let state = try NoteRecordingState.load(noteFolder: note)
        #expect(
            state.activeImport
                == .init(fileName: "crash.m4a", n: 1, baseSamples: 0, phase: 2))
        #expect(state.imports["crash.m4a"]?.status == .transcribing)
        #expect(FileManager.default.fileExists(atPath: pendingDir.appending(path: "1.json").path))
        #expect(FileManager.default.fileExists(atPath: pendingDir.appending(path: "1.webm").path))
    }
}
