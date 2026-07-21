import Testing

@testable import CodexKit

@Suite("MarkdownSegmenter")
struct MarkdownSegmenterTests {
    @Test("splits fenced code out of prose")
    func fences() {
        let segments = MarkdownSegmenter.segments(
            "Before\n```swift\nlet x = 1\n```\nAfter")
        #expect(
            segments == [
                .text("Before"),
                .code(language: "swift", body: "let x = 1"),
                .text("After")
            ])
    }

    @Test("unterminated fence swallows the rest as code")
    func unterminated() {
        #expect(
            MarkdownSegmenter.segments("hi\n```\nstill code") == [
                .text("hi"), .code(language: nil, body: "still code")
            ])
    }

    @Test("plain text is one segment; empty is none")
    func plain() {
        #expect(MarkdownSegmenter.segments("just words") == [.text("just words")])
        #expect(MarkdownSegmenter.segments("").isEmpty)
        #expect(MarkdownSegmenter.segments("  \n").isEmpty)
    }
}
