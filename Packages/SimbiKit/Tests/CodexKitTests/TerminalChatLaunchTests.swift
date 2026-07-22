import Foundation
import Testing

@testable import CodexKit

@Suite("TerminalChatLaunch")
struct TerminalChatLaunchTests {
    private struct TempNote {
        let home: URL
        let note: URL
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    private func makeNote(files: [String: String]) throws -> TempNote {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "terminal-launch-\(UUID().uuidString)")
        let note = home.appending(path: "Work/Standup")
        try FileManager.default.createDirectory(
            at: note, withIntermediateDirectories: true)
        for (name, content) in files {
            let target = note.appending(path: name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: true, encoding: .utf8)
        }
        return TempNote(home: home, note: note)
    }

    private let installation = CodexInstallation(
        binaryURL: URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        codexHomeURL: URL(filePath: "/Users/u/.codex"))

    @Test("command line is constant and env-indirected — no per-note text")
    func commandLineShape() {
        let command = TerminalChatLaunch.commandLine
        #expect(command.hasPrefix("exec \"$SIMBI_CODEX_BIN\""))
        #expect(command.contains("-C \"$SIMBI_NOTE_DIR\""))
        #expect(command.contains("--add-dir \"$SIMBI_HOME_ROOT\""))
        #expect(command.contains("-s workspace-write"))
        #expect(command.contains("-a on-request"))
        #expect(command.contains("-c developer_instructions=\"$SIMBI_CHAT_CONTEXT\""))
    }

    @Test("env vars carry the binary, dirs, codex home, and context")
    func envVars() throws {
        let temp = try makeNote(files: ["note.md": "hi"])
        defer { temp.cleanup() }
        let launch = TerminalChatLaunch.forNote(
            noteFolderURL: temp.note, homeRootURL: temp.home, installation: installation)
        #expect(launch.envVars["SIMBI_CODEX_BIN"] == installation.binaryURL.path)
        #expect(launch.envVars["CODEX_HOME"] == "/Users/u/.codex")
        #expect(launch.envVars["SIMBI_NOTE_DIR"] == temp.note.path)
        #expect(launch.envVars["SIMBI_HOME_ROOT"] == temp.home.path)
        #expect(
            launch.envVars["SIMBI_CHAT_CONTEXT"]
                == TerminalChatLaunch.developerInstructions(
                    noteFolderURL: temp.note, homeRootURL: temp.home))
    }

    @Test("instructions inventory the files that exist")
    func instructionsListFiles() throws {
        let temp = try makeNote(files: [
            "note.md": "hello",
            "transcript.vtt": "WEBVTT",
            "context/slides.md": "converted",
            "files/slides.pdf": "raw",
        ])
        defer { temp.cleanup() }
        let text = TerminalChatLaunch.developerInstructions(
            noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(text.contains("Work/Standup"))
        #expect(text.contains("note.md"))
        #expect(text.contains("transcript.vtt"))
        #expect(text.contains("context/slides.md"))
        #expect(text.contains("files/slides.pdf"))
    }

    @Test("instructions say so when the note has no files yet")
    func instructionsEmptyNote() throws {
        let temp = try makeNote(files: [:])
        defer { temp.cleanup() }
        let text = TerminalChatLaunch.developerInstructions(
            noteFolderURL: temp.note, homeRootURL: temp.home)
        #expect(text.contains("no files yet"))
        #expect(!text.contains("currently contains"))
    }
}
