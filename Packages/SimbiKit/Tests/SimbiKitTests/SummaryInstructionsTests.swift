import Foundation
import Testing

@testable import SimbiKit

@Suite("SummaryInstructions")
struct SummaryInstructionsTests {
    @Test("summary case is registered with the expected identity")
    func caseIdentity() {
        #expect(AgentInstructions.summary.fileName == "SUMMARY.md")
        #expect(AgentInstructions.summary.title == "AI notes")
        #expect(AgentInstructions.summary.variables.isEmpty)
        #expect(AgentInstructions.allCases.contains(.summary))
        let text = AgentInstructions.summary.defaultContents
        #expect(text.contains("[["))  // encodes the citation convention
        #expect(!text.contains("\u{2014}"))  // instructions follow the no-em-dash copy rule
    }

    @Test("SUMMARY.md at the home root and summary.md in a note never reach the sidebar")
    func sidebarInvisibility() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "instr".write(
            to: root.appending(path: "SUMMARY.md"), atomically: true, encoding: .utf8)
        let note = root.appending(path: "Standup")
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
        try "note".write(
            to: note.appending(path: "note.md"), atomically: true, encoding: .utf8)
        try "ai".write(
            to: note.appending(path: "summary.md"), atomically: true, encoding: .utf8)

        let tree = FileTreeScanner.scan(root: root)
        #expect(!tree.contains { $0.name == "SUMMARY.md" })
        let noteNode = try #require(tree.first { $0.name == "Standup" })
        #expect(noteNode.kind == .note)
        #expect(noteNode.children == nil)  // leaf: summary.md can never surface
    }
}
