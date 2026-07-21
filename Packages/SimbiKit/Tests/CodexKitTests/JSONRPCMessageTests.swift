import Foundation
import Testing

@testable import CodexKit

@Suite("JSONRPCMessage")
struct JSONRPCMessageTests {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test("id without method is a response")
    func response() {
        let message = JSONRPCMessage.classify(object(#"{"id": 3, "result": {"ok": true}}"#))
        guard case .response(let id, _) = message else {
            Issue.record("expected response, got \(message)")
            return
        }
        #expect(id == 3)
    }

    @Test("method with id is a server request, int or string id")
    func serverRequest() {
        let intId = JSONRPCMessage.classify(
            object(
                #"{"id": 7, "method": "item/commandExecution/requestApproval", "params": {"command": "git push"}}"#
            ))
        guard case .serverRequest(let id, let method, let params) = intId else {
            Issue.record("expected serverRequest, got \(intId)")
            return
        }
        #expect(id == .int(7))
        #expect(method == "item/commandExecution/requestApproval")
        #expect(params["command"] as? String == "git push")

        let stringId = JSONRPCMessage.classify(
            object(#"{"id": "req-1", "method": "item/fileChange/requestApproval", "params": {}}"#))
        guard case .serverRequest(let sid, _, _) = stringId else {
            Issue.record("expected serverRequest, got \(stringId)")
            return
        }
        #expect(sid == .string("req-1"))
    }

    @Test("method without id is a notification")
    func notification() {
        let message = JSONRPCMessage.classify(
            object(#"{"method": "item/agentMessage/delta", "params": {"delta": "hi"}}"#))
        guard case .notification(let method, let params) = message else {
            Issue.record("expected notification, got \(message)")
            return
        }
        #expect(method == "item/agentMessage/delta")
        #expect(params["delta"] as? String == "hi")
    }

    @Test("garbage is invalid")
    func invalid() {
        guard case .invalid = JSONRPCMessage.classify(object(#"{"foo": 1}"#)) else {
            Issue.record("expected invalid")
            return
        }
    }
}
