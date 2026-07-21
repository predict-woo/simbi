import Foundation
import Testing

@testable import CodexKit

@Suite("ChatContextPrompt")
struct ChatContextPromptTests {
    private struct TempNote {
        let home: URL
        let note: URL
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    private func makeNote(files: [String: String]) throws -> TempNote {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "chat-prompt-\(UUID().uuidString)")
        let note = home.appending(path: "Work/Standup")
        try FileManager.default.createDirectory(
            at: note.appending(path: "context"), withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(
                to: note.appending(path: name), atomically: true, encoding: .utf8)
        }
        return TempNote(home: home, note: note)
    }

    @Test("embeds every file under its cwd-relative path and explains editing")
    func embedsFiles() throws {
        let temp = try makeNote(files: [
            "note.md": "Hello note",
            "transcript.vtt": "WEBVTT\n\n00:00.000 --> 00:01.000\n<v Speaker 1>hi",
            "context/b.md": "second",
            "context/a.md": "first"
        ])
        defer { temp.cleanup() }

        let prompt = ChatContextPrompt.build(noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(prompt.hasPrefix(ChatContextPrompt.sentinel))
        #expect(prompt.contains("===== BEGIN Work/Standup/note.md =====\nHello note"))
        #expect(prompt.contains("===== BEGIN Work/Standup/transcript.vtt ====="))
        // context files sorted by name
        let first = prompt.range(of: "context/a.md")!.lowerBound
        let second = prompt.range(of: "context/b.md")!.lowerBound
        #expect(first < second)
        // The agent is told where the real files live for edits.
        #expect(prompt.contains("edit those files on disk"))
        #expect(prompt.contains("`Work/Standup`"))
    }

    @Test("oversized files are truncated with a pointer to the real file")
    func truncation() throws {
        let big = String(repeating: "x", count: ChatContextPrompt.perFileLimit + 500)
        let temp = try makeNote(files: ["transcript.vtt": big])
        defer { temp.cleanup() }

        let prompt = ChatContextPrompt.build(noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(prompt.contains("[truncated — the full file is at `Work/Standup/transcript.vtt`]"))
        #expect(prompt.count < big.count + 2_000)
    }

    @Test("empty note still explains the layout")
    func emptyNote() throws {
        let temp = try makeNote(files: [:])
        defer { temp.cleanup() }

        let prompt = ChatContextPrompt.build(noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(prompt.hasPrefix(ChatContextPrompt.sentinel))
        #expect(prompt.contains("no files yet"))
    }
}
