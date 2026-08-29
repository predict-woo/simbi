import Foundation
import SimbiKit
import Testing

@testable import SimbiUI

@Suite("PlaybackController live file")
struct PlaybackControllerTests {
    @Test("audio availability follows external creation and deletion")
    @MainActor
    func followsAudioFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "simbi-playback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = NoteLayout.audioURL(noteFolder: folder)
        let controller = PlaybackController(noteFolderURL: folder)
        #expect(!controller.hasAudio)

        try Data().write(to: audio)
        controller.refreshFileState()
        #expect(controller.hasAudio)

        try FileManager.default.removeItem(at: audio)
        controller.refreshFileState()
        #expect(!controller.hasAudio)
    }
}
