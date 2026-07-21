import Foundation
import Testing

@testable import CodexKit

@Suite("ChatEventParser")
struct ChatEventsTests {
    private func params(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test("agent message delta")
    func delta() {
        let parsed = ChatEventParser.parse(
            method: "item/agentMessage/delta",
            params: params(
                #"{"threadId": "thr_1", "turnId": "turn_1", "itemId": "item_9", "delta": "Hel"}"#))
        #expect(parsed?.threadId == "thr_1")
        #expect(parsed?.event == .agentMessageDelta(itemId: "item_9", delta: "Hel"))
    }

    @Test("turn lifecycle")
    func turns() {
        let started = ChatEventParser.parse(
            method: "turn/started",
            params: params(
                #"{"threadId": "thr_1", "turn": {"id": "turn_1", "status": "inProgress"}}"#))
        #expect(started?.event == .turnStarted(turnId: "turn_1"))

        let failed = ChatEventParser.parse(
            method: "turn/completed",
            params: params(#"{"threadId": "thr_1", "turn": {"id": "turn_1", "status": "failed"}}"#))
        #expect(failed?.event == .turnCompleted(status: "failed"))
    }

    @Test("item completed: agentMessage, commandExecution, fileChange")
    func items() {
        let agent = ChatEventParser.parse(
            method: "item/completed",
            params: params(
                #"{"threadId": "thr_1", "turnId": "t", "item": {"type": "agentMessage", "id": "i1", "text": "Done."}}"#
            ))
        #expect(
            agent?.event == .itemCompleted(ChatItem(id: "i1", detail: .agentMessage(text: "Done.")))
        )

        let command = ChatEventParser.parse(
            method: "item/completed",
            params: params(
                #"""
                {"threadId": "thr_1", "turnId": "t", "item": {"type": "commandExecution",
                 "id": "i2", "command": "ls -la", "cwd": "/tmp", "status": "completed",
                 "aggregatedOutput": "total 0", "exitCode": 0}}
                """#))
        #expect(
            command?.event
                == .itemCompleted(
                    ChatItem(
                        id: "i2",
                        detail: .commandExecution(
                            command: "ls -la", status: "completed", output: "total 0"))))

        let file = ChatEventParser.parse(
            method: "item/started",
            params: params(
                #"""
                {"threadId": "thr_1", "turnId": "t", "item": {"type": "fileChange", "id": "i3",
                 "status": "inProgress", "changes": [{"path": "/Users/u/Simbi/note.md", "kind": "edit"}]}}
                """#))
        #expect(
            file?.event
                == .itemStarted(
                    ChatItem(
                        id: "i3",
                        detail: .fileChange(
                            files: ["/Users/u/Simbi/note.md"], status: "inProgress"))))
    }

    @Test("user message and unknown types survive")
    func userAndUnknown() {
        let user = ChatEventParser.item(
            from: params(
                #"{"type": "userMessage", "id": "u1", "content": [{"type": "text", "text": "hi"}]}"#
            ))
        #expect(user == ChatItem(id: "u1", detail: .userMessage(text: "hi")))

        let odd = ChatEventParser.item(
            from: params(#"{"type": "mcpToolCall", "id": "m1", "server": "s", "tool": "t"}"#))
        #expect(odd == ChatItem(id: "m1", detail: .other(type: "mcpToolCall")))
    }

    @Test("reasoning summarizes; unrelated methods return nil")
    func reasoningAndNil() {
        let reasoning = ChatEventParser.item(
            from: params(
                #"{"type": "reasoning", "id": "r1", "summary": ["Weighing options"], "content": []}"#
            ))
        #expect(reasoning == ChatItem(id: "r1", detail: .reasoning(summary: "Weighing options")))
        #expect(ChatEventParser.parse(method: "turn/diff/updated", params: [:]) == nil)
    }
}
