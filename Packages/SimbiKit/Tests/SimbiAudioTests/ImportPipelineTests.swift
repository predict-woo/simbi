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

private struct StubTranscriber: Transcriber {
    func transcribe(webmFile: URL) async throws -> String { "[import test]" }
}

@Suite("ImportPipeline phase 1")
struct ImportPipelinePhase1Tests {
    private func makeNote() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "# note\n".write(to: url.appending(path: "note.md"), atomically: true, encoding: .utf8)
        return url
    }

    /// 10 s of quiet noise (constant tone would be fine too — never played).
    private func pcm(seconds: Int) -> [Float] {
        (0..<(seconds * 16000)).map { _ in Float.random(in: -0.05...0.05) }
    }

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
            $0.activeImport = .init(fileName: "crash.mp4", n: 2, baseSamples: 5 * 16000, phase: 1)
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
        #expect(abs(Int(probe.endMilliseconds) - 5000) <= Int(OpusWebMFormat.clusterMilliseconds))
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
