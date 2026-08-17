import Foundation
import Testing

@testable import CodexKit

@Suite("NoteSummarizer")
struct NoteSummarizerTests {
    @Test("agentMessage items are captured; other items ignored")
    func itemParsing() throws {
        let good = try JSONSerialization.data(withJSONObject: [
            "threadId": "t1",
            "item": ["id": "i1", "type": "agentMessage", "text": "DONE"],
        ])
        let parsed = try #require(CodexWorkerTurnRunner.agentMessage(fromItemCompleted: good))
        #expect(parsed.threadId == "t1")
        #expect(parsed.text == "DONE")

        let reasoning = try JSONSerialization.data(withJSONObject: [
            "threadId": "t1", "item": ["id": "i2", "type": "reasoning", "text": "hmm"],
        ])
        #expect(CodexWorkerTurnRunner.agentMessage(fromItemCompleted: reasoning) == nil)
        #expect(CodexWorkerTurnRunner.agentMessage(fromItemCompleted: Data("junk".utf8)) == nil)
    }

    @Test("a FAILED reply yields its trimmed first line as the reason")
    func failedReply() {
        let live = "FAILED: workspace is read-only, so summary.md could not be updated."
        #expect(CodexWorkerTurnRunner.reportedFailure(in: live) == live)
        // Surrounding whitespace is not part of the reply.
        #expect(CodexWorkerTurnRunner.reportedFailure(in: "\n  \(live)  \n") == live)
    }

    @Test("the FAILED prefix check is case-insensitive")
    func failedCaseInsensitive() {
        #expect(CodexWorkerTurnRunner.reportedFailure(in: "failed: x") == "failed: x")
    }

    @Test("a DONE reply is not a failure")
    func doneReply() {
        #expect(CodexWorkerTurnRunner.reportedFailure(in: "DONE") == nil)
        #expect(CodexWorkerTurnRunner.reportedFailure(in: "All good, summary written.") == nil)
    }

    @Test("a multi-line FAILED reply keeps only the first line")
    func multilineFailedReply() {
        let reply = "FAILED: could not read transcript.vtt\nIt seems to be missing.\nSorry."
        #expect(
            CodexWorkerTurnRunner.reportedFailure(in: reply) == "FAILED: could not read transcript.vtt")
    }
}
