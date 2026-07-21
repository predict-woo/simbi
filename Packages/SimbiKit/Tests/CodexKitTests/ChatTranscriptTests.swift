import Testing

@testable import CodexKit

@Suite("ChatTranscript")
struct ChatTranscriptTests {
    @Test("deltas accumulate then completion is authoritative")
    func streaming() {
        var transcript = ChatTranscript()
        transcript.apply(.turnStarted(turnId: "t1"))
        #expect(transcript.turnActive)
        #expect(transcript.activeTurnId == "t1")
        transcript.apply(.agentMessageDelta(itemId: "a1", delta: "Hel"))
        transcript.apply(.agentMessageDelta(itemId: "a1", delta: "lo"))
        #expect(transcript.rows == [.agent(id: "a1", markdown: "Hello", streaming: true)])
        transcript.apply(.itemCompleted(ChatItem(id: "a1", detail: .agentMessage(text: "Hello!"))))
        #expect(transcript.rows == [.agent(id: "a1", markdown: "Hello!", streaming: false)])
        transcript.apply(.turnCompleted(status: "completed"))
        #expect(!transcript.turnActive)
        #expect(transcript.rows.count == 1)  // no banner on clean completion
    }

    @Test("command rows upsert started -> completed")
    func commandLifecycle() {
        var transcript = ChatTranscript()
        transcript.apply(
            .itemStarted(
                ChatItem(
                    id: "c1",
                    detail: .commandExecution(command: "ls", status: "inProgress", output: nil))))
        transcript.apply(
            .itemCompleted(
                ChatItem(
                    id: "c1",
                    detail: .commandExecution(command: "ls", status: "completed", output: "a.txt")))
        )
        #expect(
            transcript.rows == [.command(id: "c1", command: "ls", status: "completed", output: "a.txt")])
    }

    @Test("failed turn appends a banner; local user rows are immediate")
    func failureAndLocalEcho() {
        var transcript = ChatTranscript()
        transcript.appendLocalUser(text: "do the thing")
        #expect(transcript.rows == [.user(id: "local-1", text: "do the thing")])
        transcript.apply(.turnCompleted(status: "failed"))
        #expect(transcript.rows.last == .banner(id: "banner-1", text: "The turn failed."))
    }

    @Test("wire echo of the sent message replaces the local row, not duplicates")
    func echoDedup() {
        var transcript = ChatTranscript()
        transcript.appendLocalUser(text: "hi")
        transcript.apply(.itemCompleted(ChatItem(id: "u9", detail: .userMessage(text: "hi"))))
        #expect(transcript.rows == [.user(id: "u9", text: "hi")])
    }

    @Test("history hydration maps items to rows; reasoning and unknown are quiet")
    func hydration() {
        let transcript = ChatTranscript(history: [
            ChatItem(id: "u1", detail: .userMessage(text: "hi")),
            ChatItem(id: "a1", detail: .agentMessage(text: "hello")),
            ChatItem(id: "r1", detail: .reasoning(summary: "")),
            ChatItem(id: "m1", detail: .other(type: "mcpToolCall")),
            ChatItem(id: "f1", detail: .fileChange(files: ["/n/note.md"], status: "completed"))
        ])
        #expect(
            transcript.rows == [
                .user(id: "u1", text: "hi"),
                .agent(id: "a1", markdown: "hello", streaming: false),
                .quiet(id: "r1", text: "Thinking…"),
                .quiet(id: "m1", text: "mcpToolCall"),
                .fileChange(id: "f1", files: ["/n/note.md"], status: "completed")
            ])
    }
}
