import Foundation
import Testing

@testable import CodexKit

@Suite("AppServerClient endpoint parsing")
struct AppServerEndpointTests {
    @Test("initialize opts into the project API")
    func enablesProjectAPI() {
        let params = AppServerClient.initializeParams(version: "1.2.1")
        let capabilities = params["capabilities"] as? [String: any Sendable]
        #expect(capabilities?["experimentalApi"] as? Bool == true)
    }

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
