import Foundation
import Testing

@testable import CodexKit

@Suite("AppServerClient endpoint parsing")
struct AppServerEndpointTests {
    @Test("extracts the ws endpoint from the listen line")
    func parsesListenLine() {
        #expect(
            AppServerClient.listenEndpoint(
                fromLine: "  listening on: ws://127.0.0.1:51859")
                == "ws://127.0.0.1:51859")
    }

    @Test("ignores unrelated startup lines")
    func ignoresOtherLines() {
        #expect(
            AppServerClient.listenEndpoint(
                fromLine: "codex app-server (WebSockets)") == nil)
        #expect(
            AppServerClient.listenEndpoint(
                fromLine: "  readyz: http://127.0.0.1:51859/readyz") == nil)
        #expect(AppServerClient.listenEndpoint(fromLine: "") == nil)
    }
}
