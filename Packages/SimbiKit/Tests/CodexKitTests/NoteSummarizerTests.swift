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
        let parsed = try #require(NoteSummarizer.agentMessage(fromItemCompleted: good))
        #expect(parsed.threadId == "t1")
        #expect(parsed.text == "DONE")

        let reasoning = try JSONSerialization.data(withJSONObject: [
            "threadId": "t1", "item": ["id": "i2", "type": "reasoning", "text": "hmm"],
        ])
        #expect(NoteSummarizer.agentMessage(fromItemCompleted: reasoning) == nil)
        #expect(NoteSummarizer.agentMessage(fromItemCompleted: Data("junk".utf8)) == nil)
    }

    @Test("a FAILED reply yields its trimmed first line as the reason")
    func failedReply() {
        let live = "FAILED: workspace is read-only, so summary.md could not be updated."
        #expect(NoteSummarizer.reportedFailure(in: live) == live)
        // Surrounding whitespace is not part of the reply.
        #expect(NoteSummarizer.reportedFailure(in: "\n  \(live)  \n") == live)
    }

    @Test("the FAILED prefix check is case-insensitive")
    func failedCaseInsensitive() {
        #expect(NoteSummarizer.reportedFailure(in: "failed: x") == "failed: x")
    }

    @Test("a DONE reply is not a failure")
    func doneReply() {
        #expect(NoteSummarizer.reportedFailure(in: "DONE") == nil)
        #expect(NoteSummarizer.reportedFailure(in: "All good, summary written.") == nil)
    }

    @Test("a multi-line FAILED reply keeps only the first line")
    func multilineFailedReply() {
        let reply = "FAILED: could not read transcript.vtt\nIt seems to be missing.\nSorry."
        #expect(
            NoteSummarizer.reportedFailure(in: reply) == "FAILED: could not read transcript.vtt")
    }
}
