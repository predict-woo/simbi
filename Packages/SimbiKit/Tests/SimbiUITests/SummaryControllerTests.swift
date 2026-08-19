import Foundation
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
