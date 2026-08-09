import Foundation
import Testing

@testable import SimbiUI

@Suite("SummaryController")
struct SummaryControllerTests {
    @Test("auto-generation gating")
    func autoGate() {
        #expect(
            SummaryController.shouldAutoGenerate(
                transcriptHasCues: true, codexAvailable: true, alreadyWorking: false,
                recordingActive: false))
        #expect(
            !SummaryController.shouldAutoGenerate(
                transcriptHasCues: false, codexAvailable: true, alreadyWorking: false,
                recordingActive: false))
        #expect(
            !SummaryController.shouldAutoGenerate(
                transcriptHasCues: true, codexAvailable: false, alreadyWorking: false,
                recordingActive: false))
        #expect(
            !SummaryController.shouldAutoGenerate(
                transcriptHasCues: true, codexAvailable: true, alreadyWorking: true,
                recordingActive: false))
        // Spec §3: no trigger while recording, ever.
        #expect(
            !SummaryController.shouldAutoGenerate(
                transcriptHasCues: true, codexAvailable: true, alreadyWorking: false,
                recordingActive: true))
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
