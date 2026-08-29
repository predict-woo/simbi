import Foundation
import Testing

@testable import SimbiUI

@Suite("AutosavingDocument live file")
struct AutosavingDocumentTests {
    @Test("a clean editor follows external changes and deletion")
    @MainActor
    func cleanEditorFollowsDisk() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "summary.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let document = AutosavingDocument(fileURL: file)

        try "external".write(to: file, atomically: true, encoding: .utf8)
        document.refreshFromDisk()
        #expect(document.text == "external")
        #expect(!document.hasConflict)

        try FileManager.default.removeItem(at: file)
        document.refreshFromDisk()
        #expect(document.text.isEmpty)
        document.saveNow()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("an external write cancels a pending stale autosave")
    @MainActor
    func externalWriteWinsPendingAutosave() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "summary.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let document = AutosavingDocument(fileURL: file)

        document.text = "local"
        document.scheduleAutosave()
        try "external".write(to: file, atomically: true, encoding: .utf8)
        document.refreshFromDisk()
        try await Task.sleep(for: .milliseconds(700))

        #expect(document.hasConflict)
        #expect(document.text == "local")
        #expect(try String(contentsOf: file, encoding: .utf8) == "external")

        document.reloadFromDisk()
        #expect(!document.hasConflict)
        #expect(document.text == "external")
    }

    @Test("overwriting a conflict is explicit and self-save events are ignored")
    @MainActor
    func explicitOverwrite() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "summary.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let document = AutosavingDocument(fileURL: file)

        document.text = "local"
        try "external".write(to: file, atomically: true, encoding: .utf8)
        document.refreshFromDisk()
        document.overwriteDisk()
        document.refreshFromDisk()

        #expect(!document.hasConflict)
        #expect(document.text == "local")
        #expect(try String(contentsOf: file, encoding: .utf8) == "local")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "simbi-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
