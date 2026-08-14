import Foundation
import Testing

@testable import SimbiUI

@Suite("TitleController")
struct TitleControllerTests {
    @Test("auto-generation gating")
    func autoGate() {
        #expect(
            TitleController.shouldAutoGenerate(
                titleIsDefault: true, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: false, recordingActive: false))
        // A renamed note is never touched — the whole point of the feature.
        #expect(
            !TitleController.shouldAutoGenerate(
                titleIsDefault: false, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                titleIsDefault: true, transcriptHasCues: false, codexAvailable: true,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                titleIsDefault: true, transcriptHasCues: true, codexAvailable: false,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                titleIsDefault: true, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: true, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                titleIsDefault: true, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: false, recordingActive: true))
    }

    @Test("a finished title renames only a still-default note")
    @MainActor
    func renameRecheck() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "New Note", directoryHint: .isDirectory)
        let controller = TitleController(noteFolderURL: url)
        var renamedTo: String?
        controller.renameNote = { renamedTo = $0 }

        controller.applyGeneratedTitle("Design Sync", currentFolderName: "New Note")
        #expect(renamedTo == "Design Sync")

        // The user renamed while the titler ran: their name wins.
        renamedTo = nil
        controller.applyGeneratedTitle("Design Sync", currentFolderName: "My Meeting")
        #expect(renamedTo == nil)
    }
}
