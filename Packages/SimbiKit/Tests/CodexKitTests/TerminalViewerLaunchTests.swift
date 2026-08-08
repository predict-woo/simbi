import Foundation
import Testing

@testable import CodexKit

@Suite("TerminalViewerLaunch")
struct TerminalViewerLaunchTests {
    private let launch = TerminalViewerLaunch.forThread(
        threadId: "019f0000-aaaa-bbbb-cccc-ddddeeeeffff",
        appServerURL: "ws://127.0.0.1:51859")

    @Test("env vars carry the endpoint, thread id, binary, and CODEX_HOME")
    func envVars() {
        #expect(launch.envVars["SIMBI_APPSERVER_URL"] == "ws://127.0.0.1:51859")
        #expect(
            launch.envVars["SIMBI_THREAD_ID"] == "019f0000-aaaa-bbbb-cccc-ddddeeeeffff")
        #expect(launch.envVars["SIMBI_CODEX_BIN"]?.isEmpty == false)
        #expect(launch.envVars["CODEX_HOME"]?.isEmpty == false)
    }

    @Test("command line survives Ghostty's parsing traps")
    func commandLineShape() {
        // Ghostty prepends `exec` itself and strips a surrounding quote
        // pair (see TerminalChatLaunch.commandLine).
        #expect(!TerminalViewerLaunch.commandLine.hasPrefix("exec"))
        #expect(!TerminalViewerLaunch.commandLine.hasPrefix("\""))
        #expect(!TerminalViewerLaunch.commandLine.hasSuffix("\""))
        #expect(TerminalViewerLaunch.commandLine.contains("--remote"))
        #expect(TerminalViewerLaunch.commandLine.contains("resume"))
    }
}
