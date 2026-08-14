import Foundation
import Testing

@testable import CodexKit

@Suite("NoteTitler")
struct NoteTitlerTests {
    @Test("a clean one-line reply is the title, trimmed")
    func cleanReply() {
        #expect(NoteTitler.sanitizedTitle(from: "  Q3 Budget Review \n") == "Q3 Budget Review")
    }

    @Test("only the first line of a chatty reply counts")
    func firstLineOnly() {
        #expect(
            NoteTitler.sanitizedTitle(from: "Design Sync\nI chose this because…")
                == "Design Sync")
    }

    @Test("surrounding quotes, backticks, and code fences are stripped")
    func quotesStripped() {
        #expect(NoteTitler.sanitizedTitle(from: "\"Design Sync\"") == "Design Sync")
        #expect(NoteTitler.sanitizedTitle(from: "'Design Sync'") == "Design Sync")
        #expect(NoteTitler.sanitizedTitle(from: "“Design Sync”") == "Design Sync")
        #expect(NoteTitler.sanitizedTitle(from: "`Design Sync`") == "Design Sync")
        #expect(NoteTitler.sanitizedTitle(from: "```\nDesign Sync\n```") == "Design Sync")
    }

    @Test("path-hostile characters are made folder-safe")
    func folderSafe() {
        #expect(NoteTitler.sanitizedTitle(from: "A/B Testing Results") == "A-B Testing Results")
        #expect(NoteTitler.sanitizedTitle(from: "Budget: Q3 Review") == "Budget Q3 Review")
        #expect(NoteTitler.sanitizedTitle(from: ".hidden name") == "hidden name")
    }

    @Test("degenerate replies yield nil")
    func degenerateReplies() {
        #expect(NoteTitler.sanitizedTitle(from: "") == nil)
        #expect(NoteTitler.sanitizedTitle(from: "   \n\n") == nil)
        #expect(NoteTitler.sanitizedTitle(from: "\"\"") == nil)
        #expect(NoteTitler.sanitizedTitle(from: "...") == nil)
    }

    @Test("overlong replies are cut at a word boundary under the cap")
    func lengthCap() throws {
        let longReply = Array(repeating: "word", count: 40).joined(separator: " ")
        let title = try #require(NoteTitler.sanitizedTitle(from: longReply))
        #expect(title.count <= 64)
        #expect(!title.hasSuffix(" "))
        #expect(title.hasSuffix("word"))
    }

    @Test("a FAILED reply is recognized via the shared failure contract")
    func failedReply() {
        #expect(NoteSummarizer.reportedFailure(in: "FAILED: transcript too thin") != nil)
    }
}
