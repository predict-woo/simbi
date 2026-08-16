import Testing

@testable import SimbiAudio

@MainActor @Suite struct ModelWarmupStateTests {
    @Test func lifecycleReachesReady() {
        let state = ModelWarmupState()
        #expect(state.phase == .idle)
        state.begin()
        #expect(state.phase == .downloading(fraction: 0, detail: "Preparing"))
        state.report(sortformerFraction: 0.5, detail: "file 3 of 7")
        #expect(state.phase == .downloading(fraction: 0.5, detail: "file 3 of 7"))
        state.finish()
        #expect(state.phase == .ready)
    }

    @Test func failureThenRetryRestarts() {
        let state = ModelWarmupState()
        state.begin()
        state.fail(message: "offline")
        #expect(state.phase == .failed(message: "offline"))
        state.begin()
        #expect(state.phase == .downloading(fraction: 0, detail: "Preparing"))
    }

    @Test func readyIsTerminalAgainstLateReports() {
        let state = ModelWarmupState()
        state.begin()
        state.finish()
        state.report(sortformerFraction: 0.2, detail: "file 1 of 7")
        #expect(state.phase == .ready)
    }
}
