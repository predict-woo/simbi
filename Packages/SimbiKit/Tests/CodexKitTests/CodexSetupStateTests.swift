import Testing

@testable import CodexKit

@Suite("CodexSetupState")
struct CodexSetupStateTests {
    @Test("binary absent → notInstalled")
    func binaryAbsent() {
        #expect(CodexSetupState.resolve(isInstalled: false, isSignedIn: false) == .notInstalled)
    }

    @Test("binary absent wins even with stray credentials on disk")
    func binaryAbsentWins() {
        #expect(CodexSetupState.resolve(isInstalled: false, isSignedIn: true) == .notInstalled)
    }

    @Test("installed but signed out → signedOut")
    func signedOut() {
        #expect(CodexSetupState.resolve(isInstalled: true, isSignedIn: false) == .signedOut)
    }

    @Test("installed and signed in → connected")
    func connected() {
        #expect(CodexSetupState.resolve(isInstalled: true, isSignedIn: true) == .connected)
    }
}
