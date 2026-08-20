import Foundation
import Testing

@testable import SimbiKit

@Suite("NoteRecordingState media import fields")
struct NoteRecordingStateImportTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "state-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("round-trips activeImport and imports")
    func roundTrip() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var state = NoteRecordingState()
        state.activeImport = .init(fileName: "talk.mp4", n: 3, baseSamples: 160_000, phase: 1)
        state.imports["talk.mp4"] = .init(status: .analyzing)
        try state.save(noteFolder: folder)
        let loaded = try NoteRecordingState.load(noteFolder: folder)
        #expect(loaded.activeImport == state.activeImport)
        #expect(loaded.imports == state.imports)
    }

    @Test("decodes legacy state.json without the new keys")
    func forwardCompatible() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = NoteRecordingState.fileURL(noteFolder: folder)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"nextCueIndex": 5, "sessionCount": 1, "totalSamples": 320000}"#.utf8)
            .write(to: url)
        let loaded = try NoteRecordingState.load(noteFolder: folder)
        #expect(loaded.activeImport == nil)
        #expect(loaded.imports.isEmpty)
        #expect(loaded.nextCueIndex == 5)
    }

    @Test("decodes an activeImport written without audioTouched as untouched")
    func audioTouchedForwardCompatible() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = NoteRecordingState.fileURL(noteFolder: folder)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            #"{"activeImport": {"fileName": "talk.mp4", "n": 2, "baseSamples": 80000, "phase": 1}}"#
                .utf8
        ).write(to: url)
        let loaded = try NoteRecordingState.load(noteFolder: folder)
        #expect(loaded.activeImport?.audioTouched == false)
        #expect(loaded.activeImport?.phase == 1)
    }

    @Test("saveRecording adopts on-disk imports and activeImport")
    func saveRecordingAdopts() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The import path writes its records...
        try NoteRecordingState.update(noteFolder: folder) {
            $0.imports["talk.mp4"] = .init(status: .transcribing)
            $0.activeImport = .init(fileName: "talk.mp4", n: 1, baseSamples: 0, phase: 2)
        }
        // ...then a recorder holding a stale in-memory copy saves.
        var recorderCopy = NoteRecordingState()
        recorderCopy.totalSamples = 999
        try recorderCopy.saveRecording(noteFolder: folder)
        let disk = try NoteRecordingState.load(noteFolder: folder)
        #expect(disk.totalSamples == 999)
        #expect(disk.imports["talk.mp4"]?.status == .transcribing)
        #expect(disk.activeImport?.phase == 2)
    }
}
