import Foundation
import Testing

@testable import SimbiKit

@Suite("AgentInstructions")
struct AgentInstructionsTests {
    private func makeTempHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agent-instructions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("render substitutes spaced and unspaced placeholders")
    func renderSubstitutes() {
        let text = AgentInstructions.render(
            "Convert files/{{ file }} to context/{{file}}.md",
            variables: ["file": "slides.pdf"])
        #expect(text == "Convert files/slides.pdf to context/slides.pdf.md")
    }

    @Test("render leaves unknown placeholders verbatim")
    func renderLeavesUnknown() {
        let text = AgentInstructions.render(
            "keep {{ mystery }} as is", variables: ["file": "x"])
        #expect(text == "keep {{ mystery }} as is")
    }

    @Test("render survives regex-special values")
    func renderEscapesValues() {
        let text = AgentInstructions.render(
            "name: {{ file }}", variables: ["file": "a$0\\b (1).pdf"])
        #expect(text == "name: a$0\\b (1).pdf")
    }

    @Test("missing file falls back to the default contents")
    func missingFileFallsBack() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(
            AgentInstructions.fixer.contents(homeRootURL: home)
                == AgentInstructions.fixer.defaultContents)
    }

    @Test("a blank file counts as missing — no agent runs on empty instructions")
    func blankFileFallsBack() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "\n  \n".write(
            to: AgentInstructions.fixer.url(homeRootURL: home),
            atomically: true, encoding: .utf8)
        #expect(
            AgentInstructions.fixer.contents(homeRootURL: home)
                == AgentInstructions.fixer.defaultContents)
    }

    @Test("a user-edited file wins over the default")
    func userFileWins() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "my custom fixer rules".write(
            to: AgentInstructions.fixer.url(homeRootURL: home),
            atomically: true, encoding: .utf8)
        #expect(AgentInstructions.fixer.contents(homeRootURL: home) == "my custom fixer rules")
    }

    @Test("resolve loads the file and fills its variables")
    func resolveRendersUserTemplate() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "Note {{ note_path }}: {{ files }}".write(
            to: AgentInstructions.chat.url(homeRootURL: home),
            atomically: true, encoding: .utf8)
        let text = AgentInstructions.chat.resolve(
            homeRootURL: home,
            variables: ["note_path": "Work/Standup", "files": "No files."])
        #expect(text == "Note Work/Standup: No files.")
    }

    @Test("fingerprint is stable for equal text, distinct for different text")
    func fingerprintBehaves() {
        #expect(AgentInstructions.fingerprint("abc") == AgentInstructions.fingerprint("abc"))
        #expect(AgentInstructions.fingerprint("abc") != AgentInstructions.fingerprint("abd"))
        #expect(AgentInstructions.fingerprint("abc").count == 16)
    }

    @Test("every declared variable appears in its default template")
    func defaultsCarryTheirVariables() {
        #expect(AgentInstructions.ingest.variables == ["file", "anydoc"])
        #expect(AgentInstructions.chat.variables == ["note_path", "files"])
        for file in AgentInstructions.allCases {
            for variable in file.variables {
                #expect(file.defaultContents.contains("{{ \(variable) }}"))
            }
        }
    }

    @Test("titler instructions are a bootstrapped TITLE.md with no variables")
    func titlerCaseShape() {
        #expect(AgentInstructions.title.fileName == "TITLE.md")
        #expect(AgentInstructions.title.title == "Note title")
        #expect(AgentInstructions.title.variables.isEmpty)
        #expect(AgentInstructions.allCases.contains(.title))
    }

    @Test("every default prompt carries the stay-in-scope guidance")
    func defaultsCarryScopeGuidance() {
        for file in AgentInstructions.allCases {
            #expect(
                file.defaultContents.contains("unless the user explicitly asks"),
                "\(file.fileName) lacks the scope guidance")
        }
    }

    @Test("default ingest template renders a runnable anydoc command")
    func defaultIngestRendersAnydoc() {
        let text = AgentInstructions.render(
            AgentInstructions.ingest.defaultContents,
            variables: ["file": "deck.pptx", "anydoc": "/Applications/Simbi.app/Contents/Helpers/anydoc"])
        #expect(text.contains("\"/Applications/Simbi.app/Contents/Helpers/anydoc\" \"files/deck.pptx\""))
        #expect(text.contains("context/deck.pptx.md"))
        #expect(!text.contains("{{"))
    }
}
