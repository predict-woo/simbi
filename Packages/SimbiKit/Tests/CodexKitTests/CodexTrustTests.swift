import Foundation
import Testing

@testable import CodexKit

@Suite("CodexTrust")
struct CodexTrustTests {
    private func makeHome() throws -> (installation: CodexInstallation, configURL: URL) {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "codex-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let installation = CodexInstallation(
            binaryURL: home.appending(path: "codex"), codexHomeURL: home)
        return (installation, home.appending(path: "config.toml"))
    }

    @Test("appends a trusted entry, creating config.toml if missing")
    func appendsEntry() throws {
        let (installation, configURL) = try makeHome()
        let note = URL(filePath: "/tmp/Simbi/My Note")
        CodexTrust.ensureTrusted(directory: note, installation: installation)
        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.contains("[projects.\"/tmp/Simbi/My Note\"]"))
        #expect(config.contains("trust_level = \"trusted\""))
    }

    @Test("preserves existing config content")
    func preservesExisting() throws {
        let (installation, configURL) = try makeHome()
        try "model = \"gpt-5\"".write(to: configURL, atomically: true, encoding: .utf8)
        CodexTrust.ensureTrusted(
            directory: URL(filePath: "/tmp/Simbi/Note"), installation: installation)
        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.hasPrefix("model = \"gpt-5\""))
        #expect(config.contains("[projects.\"/tmp/Simbi/Note\"]"))
    }

    @Test("second call is a no-op")
    func idempotent() throws {
        let (installation, configURL) = try makeHome()
        let note = URL(filePath: "/tmp/Simbi/Note")
        CodexTrust.ensureTrusted(directory: note, installation: installation)
        let first = try String(contentsOf: configURL, encoding: .utf8)
        CodexTrust.ensureTrusted(directory: note, installation: installation)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == first)
    }

    @Test("an explicitly untrusted entry is left untouched")
    func respectsUntrusted() throws {
        let (installation, configURL) = try makeHome()
        let entry = "[projects.\"/tmp/Simbi/Note\"]\ntrust_level = \"untrusted\"\n"
        try entry.write(to: configURL, atomically: true, encoding: .utf8)
        CodexTrust.ensureTrusted(
            directory: URL(filePath: "/tmp/Simbi/Note"), installation: installation)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == entry)
    }

    @Test("quotes in the note name are TOML-escaped")
    func escapesQuotes() throws {
        let (installation, configURL) = try makeHome()
        CodexTrust.ensureTrusted(
            directory: URL(filePath: "/tmp/Simbi/My \"cool\" Note"),
            installation: installation)
        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.contains("[projects.\"/tmp/Simbi/My \\\"cool\\\" Note\"]"))
    }

    @Test("missing codex home writes nothing")
    func missingHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "codex-trust-absent-\(UUID().uuidString)")
        let installation = CodexInstallation(
            binaryURL: home.appending(path: "codex"), codexHomeURL: home)
        CodexTrust.ensureTrusted(
            directory: URL(filePath: "/tmp/Simbi/Note"), installation: installation)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "config.toml").path))
    }
}
