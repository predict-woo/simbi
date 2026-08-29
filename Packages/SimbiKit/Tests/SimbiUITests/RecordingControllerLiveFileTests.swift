import Foundation
import SimbiAudio
import SimbiKit
import Testing

@testable import SimbiUI

@Suite("RecordingController live file")
struct RecordingControllerLiveFileTests {
    @Test("idle recording metadata follows state.json")
    @MainActor
    func followsStateFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "simbi-recording-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = RecordingController(noteFolderURL: folder)
        #expect(!controller.hasRecording)

        try NoteRecordingState(
            sessionCount: 1, totalSamples: CutConstants.sampleRate,
            fixerThreadId: "thread-id"
        ).save(noteFolder: folder)
        controller.refreshFileState()

        #expect(controller.hasRecording)
        #expect(controller.hasFixerThread)
        #expect(controller.elapsed == 1)
    }
}
