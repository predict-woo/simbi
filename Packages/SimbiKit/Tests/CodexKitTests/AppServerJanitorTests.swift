import Testing

@testable import CodexKit

@Suite struct AppServerJanitorTests {
    let codex = "/Applications/ChatGPT.app/Contents/Resources/codex"

    @Test func matchesOnlyOrphanedServersWithOurSpawnSignature() {
        let listing = """
              3430     1 \(codex) app-server --listen ws://127.0.0.1:0
             29313 28245 \(codex) app-server --listen ws://127.0.0.1:0
             94455 94314 \(codex) -c features.code_mode_host=true app-server --analytics-default-enabled
             94461     1 \(codex) app-server --listen ws://127.0.0.1:0
               123     1 /usr/bin/tail -f /var/log/system.log
            """
        let pids = AppServerJanitor.orphanPIDs(inPSListing: listing, binaryPath: codex)
        #expect(pids == [3430, 94461])
    }

    @Test func ignoresDifferentListenArguments() {
        // A server someone started by hand on a fixed port is not ours.
        let listing = "  77     1 \(codex) app-server --listen ws://127.0.0.1:5555"
        #expect(AppServerJanitor.orphanPIDs(inPSListing: listing, binaryPath: codex).isEmpty)
    }

    @Test func ignoresMalformedLines() {
        let listing = """
            garbage
            12 not-a-pid \(codex) app-server --listen ws://127.0.0.1:0
            """
        #expect(AppServerJanitor.orphanPIDs(inPSListing: listing, binaryPath: codex).isEmpty)
    }
}
