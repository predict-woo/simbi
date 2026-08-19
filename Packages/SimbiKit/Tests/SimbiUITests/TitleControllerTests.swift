import Foundation
import Testing

@testable import SimbiUI

@Suite("TitleController")
struct TitleControllerTests {
    @Test("auto-generation gating")
    func autoGate() {
        #expect(
            TitleController.shouldAutoGenerate(
                enabled: true, titleIsDefault: true, transcriptHasCues: true,
                codexAvailable: true,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                enabled: false, titleIsDefault: true, transcriptHasCues: true,
                codexAvailable: true, alreadyWorking: false, recordingActive: false))
        // A renamed note is never touched — the whole point of the feature.
        #expect(
            !TitleController.shouldAutoGenerate(
                enabled: true, titleIsDefault: false, transcriptHasCues: true,
                codexAvailable: true,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                enabled: true, titleIsDefault: true, transcriptHasCues: false,
                codexAvailable: true,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                enabled: true, titleIsDefault: true, transcriptHasCues: true,
                codexAvailable: false,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                enabled: true, titleIsDefault: true, transcriptHasCues: true,
                codexAvailable: true,
                alreadyWorking: true, recordingActive: false))
        #expect(
            !TitleController.shouldAutoGenerate(
                enabled: true, titleIsDefault: true, transcriptHasCues: true,
                codexAvailable: true,
                alreadyWorking: false, recordingActive: true))
    }

    @Test("the note is quiet only when the fixer and summarizer are both done")
    func quietGate() {
        #expect(TitleController.isQuiet(fixerStatus: .off, summaryWorking: false))
        #expect(TitleController.isQuiet(fixerStatus: .done, summaryWorking: false))
        #expect(!TitleController.isQuiet(fixerStatus: .waiting, summaryWorking: false))
        #expect(!TitleController.isQuiet(fixerStatus: .working, summaryWorking: false))
        #expect(!TitleController.isQuiet(fixerStatus: .done, summaryWorking: true))
        #expect(!TitleController.isQuiet(fixerStatus: .off, summaryWorking: true))
    }

    @Test("a note that never goes quiet is not renamed")
    @MainActor
    func renameSkippedWhenNeverQuiet() async {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "New Note", directoryHint: .isDirectory)
        let controller = TitleController(noteFolderURL: url)
        controller.quietWaitTimeout = .milliseconds(100)
        controller.quietPollInterval = .milliseconds(10)
        var renamedTo: String?
        controller.renameNote = { renamedTo = $0 }
        controller.noteIsQuiet = { false }

        await controller.awaitQuietThenApply("Design Sync")
        #expect(renamedTo == nil)
    }

    @Test("the rename lands once the note goes quiet mid-wait")
    @MainActor
    func renameAppliesWhenQuietArrives() async {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "New Note", directoryHint: .isDirectory)
        let controller = TitleController(noteFolderURL: url)
        controller.quietWaitTimeout = .seconds(5)
        controller.quietPollInterval = .milliseconds(10)
        var renamedTo: String?
        controller.renameNote = { renamedTo = $0 }
        var polls = 0
        controller.noteIsQuiet = {
            polls += 1
            return polls >= 3
        }

        await controller.awaitQuietThenApply("Design Sync")
        #expect(renamedTo == "Design Sync")
        #expect(polls >= 3)
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
