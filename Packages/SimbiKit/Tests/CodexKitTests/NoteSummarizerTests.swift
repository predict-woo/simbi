import Foundation
import Testing

@testable import CodexKit

@Suite("NoteSummarizer")
struct NoteSummarizerTests {
    @Test("fresh prompt inlines instructions, notes, and transcript")
    func freshPrompt() {
        let prompt = NoteSummarizer.prompt(
            instructions: "INSTR", myNotes: "my point", transcript: "WEBVTT",
            currentSummary: nil)
        #expect(prompt.contains("INSTR"))
        #expect(prompt.contains("my point"))
        #expect(prompt.contains("WEBVTT"))
        #expect(!prompt.contains("Current AI notes"))
    }

    @Test("empty notes are marked, not omitted")
    func emptyNotes() {
        let prompt = NoteSummarizer.prompt(
            instructions: "I", myNotes: "  \n", transcript: "T", currentSummary: nil)
        #expect(prompt.contains("(the user has not written any notes)"))
    }

    @Test("update prompt carries the current AI notes")
    func updatePrompt() {
        let prompt = NoteSummarizer.prompt(
            instructions: "I", myNotes: "N", transcript: "T", currentSummary: "OLD SUMMARY")
        #expect(prompt.contains("Current AI notes"))
        #expect(prompt.contains("OLD SUMMARY"))
    }

    @Test("agentMessage items are captured; other items ignored")
    func itemParsing() throws {
        let good = try JSONSerialization.data(withJSONObject: [
            "threadId": "t1",
            "item": ["id": "i1", "type": "agentMessage", "text": "The notes."],
        ])
        let parsed = try #require(NoteSummarizer.agentMessage(fromItemCompleted: good))
        #expect(parsed.threadId == "t1")
        #expect(parsed.text == "The notes.")

        let reasoning = try JSONSerialization.data(withJSONObject: [
            "threadId": "t1", "item": ["id": "i2", "type": "reasoning", "text": "hmm"],
        ])
        #expect(NoteSummarizer.agentMessage(fromItemCompleted: reasoning) == nil)
        #expect(NoteSummarizer.agentMessage(fromItemCompleted: Data("junk".utf8)) == nil)
    }

    @Test("normalize strips one wrapping code fence and outer whitespace")
    func normalization() {
        #expect(NoteSummarizer.normalize("# Notes\n- a\n") == "# Notes\n- a")
        #expect(NoteSummarizer.normalize("```markdown\n# Notes\n```") == "# Notes")
        #expect(NoteSummarizer.normalize("```\n# N\n- b\n```\n") == "# N\n- b")
        // A fence INSIDE the document is content, not wrapping.
        let inner = "# N\n```swift\nlet x = 1\n```"
        #expect(NoteSummarizer.normalize(inner) == inner)
    }

    @Test("a document bracketed by two distinct content fences round-trips unchanged")
    func normalizationDeclinesWhenInteriorFencesExist() {
        // Starts with one code block and ends with another: the outer lines
        // look like a wrapping fence but are content. Must not be stripped.
        let doc = "```swift\nx\n```\ntext\n```py\ny\n```"
        #expect(NoteSummarizer.normalize(doc) == doc)
    }
}
