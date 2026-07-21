import Foundation
import Testing

@testable import CodexKit

@Suite("ChatSession hydration")
struct ChatSessionTests {
    @Test("thread/read result maps turns/items to ChatItems in order")
    func hydration() {
        let data = Data(
            #"""
            {"thread": {"id": "thr_1", "turns": [
              {"id": "t1", "status": "completed", "items": [
                {"type": "userMessage", "id": "u1", "content": [{"type": "text", "text": "hi"}]},
                {"type": "agentMessage", "id": "a1", "text": "hello"}
              ]},
              {"id": "t2", "status": "completed", "items": [
                {"type": "commandExecution", "id": "c1", "command": "ls", "cwd": "/", "status": "completed"}
              ]}
            ]}}
            """#.utf8)
        #expect(
            ChatSession.history(fromThreadReadResult: data) == [
                ChatItem(id: "u1", detail: .userMessage(text: "hi")),
                ChatItem(id: "a1", detail: .agentMessage(text: "hello")),
                ChatItem(
                    id: "c1",
                    detail: .commandExecution(command: "ls", status: "completed", output: nil))
            ])
    }

    @Test("the context message is hidden from hydrated history")
    func contextEchoFiltered() {
        let data = Data(
            #"""
            {"thread": {"id": "thr_1", "turns": [
              {"id": "t1", "status": "completed", "items": [
                {"type": "userMessage", "id": "u0", "content":
                  [{"type": "text", "text": "[simbi note context]\nThe user wants to discuss…"}]},
                {"type": "agentMessage", "id": "a0", "text": "Ready."},
                {"type": "userMessage", "id": "u1", "content": [{"type": "text", "text": "hi"}]}
              ]}
            ]}}
            """#.utf8)
        #expect(ChatSession.history(fromThreadReadResult: data) == [
            ChatItem(id: "a0", detail: .agentMessage(text: "Ready.")),
            ChatItem(id: "u1", detail: .userMessage(text: "hi"))
        ])
    }

    @Test("missing turns or items hydrate to empty, not crash")
    func defensive() {
        #expect(
            ChatSession.history(fromThreadReadResult: Data(#"{"thread": {"id": "x"}}"#.utf8))
                .isEmpty)
        #expect(ChatSession.history(fromThreadReadResult: Data("null".utf8)).isEmpty)
    }
}
