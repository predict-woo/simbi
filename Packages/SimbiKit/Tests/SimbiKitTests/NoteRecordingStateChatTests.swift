import Foundation
import Testing

@testable import SimbiKit

@Suite("NoteRecordingState chat thread")
struct NoteRecordingStateChatTests {
    @Test("chatThreadId round-trips and old state files still decode")
    func chatThreadId() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "chat-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".simbi"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Old file without the key decodes to nil.
        try Data(#"{"nextCueIndex": 3}"#.utf8)
            .write(to: NoteRecordingState.fileURL(noteFolder: folder))
        var loaded = try NoteRecordingState.load(noteFolder: folder)
        #expect(loaded.chatThreadId == nil)

        try NoteRecordingState.update(noteFolder: folder) { $0.chatThreadId = "thr_42" }
        loaded = try NoteRecordingState.load(noteFolder: folder)
        #expect(loaded.chatThreadId == "thr_42")
        #expect(loaded.nextCueIndex == 3)
    }
}
