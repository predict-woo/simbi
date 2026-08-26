import Foundation
import SimbiKit
import Testing

@testable import SimbiUI

@Suite("SummaryController")
struct SummaryControllerTests {
    @Test("auto-generation gating")
    func autoGate() {
        #expect(
            SummaryController.shouldAutoGenerate(
                enabled: true, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: false,
                recordingActive: false))
        #expect(
            !SummaryController.shouldAutoGenerate(
                enabled: false, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: false, recordingActive: false))
        #expect(
            !SummaryController.shouldAutoGenerate(
                enabled: true, transcriptHasCues: false, codexAvailable: true,
                alreadyWorking: false,
                recordingActive: false))
        #expect(
            !SummaryController.shouldAutoGenerate(
                enabled: true, transcriptHasCues: true, codexAvailable: false,
                alreadyWorking: false,
                recordingActive: false))
        #expect(
            !SummaryController.shouldAutoGenerate(
                enabled: true, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: true,
                recordingActive: false))
        // Spec §3: no trigger while recording, ever.
        #expect(
            !SummaryController.shouldAutoGenerate(
                enabled: true, transcriptHasCues: true, codexAvailable: true,
                alreadyWorking: false,
                recordingActive: true))
    }

    @Test("first-generation placeholder outlives the mid-turn summary.md write")
    @MainActor
    func placeholderKeyedToRunNotFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "simbi-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = SummaryController(noteFolderURL: url)

        controller.beginRun()
        #expect(controller.status == .working)
        #expect(controller.firstGenerationInFlight)

        // The summarizer thread writes summary.md mid-turn, seconds before
        // the turn completes. The placeholder must not drop on the file
        // appearing — only when the run finishes and the editor reloads.
        try "# notes".write(to: controller.summaryFileURL, atomically: true, encoding: .utf8)
        #expect(controller.firstGenerationInFlight)

        controller.finishRun()
        #expect(!controller.firstGenerationInFlight)
        #expect(controller.generationCount == 1)
        #expect(controller.status == .idle)
    }

    @Test("updating an existing summary is not a first generation")
    @MainActor
    func updateInPlaceSkipsPlaceholder() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "simbi-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = SummaryController(noteFolderURL: url)
        try "# old notes".write(
            to: controller.summaryFileURL, atomically: true, encoding: .utf8)

        controller.beginRun()
        #expect(controller.status == .working)
        #expect(!controller.firstGenerationInFlight)
    }

    @Test("failed run drops the placeholder")
    @MainActor
    func failureDropsPlaceholder() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "simbi-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = SummaryController(noteFolderURL: url)

        controller.beginRun()
        controller.finishRun(failedWith: "AI notes couldn't be updated.")
        #expect(!controller.firstGenerationInFlight)
        #expect(controller.generationCount == 0)
        #expect(controller.status == .failed("AI notes couldn't be updated."))
    }

    @Test("first-generation offer gating")
    func offerGate() {
        #expect(
            SummaryController.shouldOfferFirstGeneration(
                enabled: true, transcriptHasCues: true, summaryExists: false,
                statusIdle: true, recordingActive: false))
        #expect(
            !SummaryController.shouldOfferFirstGeneration(
                enabled: false, transcriptHasCues: true, summaryExists: false,
                statusIdle: true, recordingActive: false))
        #expect(
            !SummaryController.shouldOfferFirstGeneration(
                enabled: true, transcriptHasCues: false, summaryExists: false,
                statusIdle: true, recordingActive: false))
        #expect(
            !SummaryController.shouldOfferFirstGeneration(
                enabled: true, transcriptHasCues: true, summaryExists: true,
                statusIdle: true, recordingActive: false))
        // Working or failed states already show the tab strip; the offer
        // exists only for the strip-less idle state.
        #expect(
            !SummaryController.shouldOfferFirstGeneration(
                enabled: true, transcriptHasCues: true, summaryExists: false,
                statusIdle: false, recordingActive: false))
        // Spec §3: no trigger while recording, ever.
        #expect(
            !SummaryController.shouldOfferFirstGeneration(
                enabled: true, transcriptHasCues: true, summaryExists: false,
                statusIdle: true, recordingActive: true))
    }

    @Test("transcriptHasCues reads the transcript on init")
    @MainActor
    func transcriptHasCuesInitialRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "simbi-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!SummaryController(noteFolderURL: url).transcriptHasCues)

        let vtt = """
            WEBVTT

            1
            00:00:00.000 --> 00:00:01.000
            <v Speaker 1>hello

            """
        try vtt.write(
            to: VTT.fileURL(noteFolder: url), atomically: true, encoding: .utf8)
        #expect(SummaryController(noteFolderURL: url).transcriptHasCues)
    }

    @Test("external summary.md delete while idle drops the held editor text")
    @MainActor
    func externalDeleteNotifies() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "simbi-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let summaryURL = NoteLayout.summaryURL(noteFolder: url)
        try "# notes".write(to: summaryURL, atomically: true, encoding: .utf8)
        let controller = SummaryController(noteFolderURL: url)
        var fired = 0
        controller.summaryFileRemovedExternally = { fired += 1 }

        try FileManager.default.removeItem(at: summaryURL)
        controller.refreshFileState()
        #expect(fired == 1)
        // No transition on a repeat refresh: fires once per disappearance.
        controller.refreshFileState()
        #expect(fired == 1)
    }

    @Test("the fresh-regenerate delete is not an external delete")
    @MainActor
    func freshRegenerateDeleteKeepsHeldText() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "simbi-sum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let summaryURL = NoteLayout.summaryURL(noteFolder: url)
        try "# notes".write(to: summaryURL, atomically: true, encoding: .utf8)
        let controller = SummaryController(noteFolderURL: url)
        var fired = 0
        controller.summaryFileRemovedExternally = { fired += 1 }

        // generate(fresh:) deletes summary.md with status already .working;
        // the held text is the failed-run recovery and must survive.
        controller.markWorkingForTesting()
        try FileManager.default.removeItem(at: summaryURL)
        controller.refreshFileState()
        #expect(fired == 0)
    }

    @Test("failed state clears on note close")
    @MainActor
    func failureClears() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "simbi-sum-\(UUID().uuidString)")
        let controller = SummaryController(noteFolderURL: url)
        controller.markFailedForTesting("boom")
        #expect(controller.status == .failed("boom"))
        controller.clearFailureOnClose()
        #expect(controller.status == .idle)
        // A close during a run must not wipe the working state.
        controller.markWorkingForTesting()
        controller.clearFailureOnClose()
        #expect(controller.status == .working)
    }
}
