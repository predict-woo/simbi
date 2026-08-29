import Foundation
import SimbiKit
import Testing

@testable import SimbiUI

@Suite("SettingsDocument live file")
struct SettingsDocumentTests {
    @Test("clean external edits reload and concurrent edits conflict")
    @MainActor
    func reloadsAndProtectsConcurrentEdits() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = SimbiHome(rootURL: root)
        try home.bootstrap()
        let document = SettingsDocument(home: home)

        var external = SimbiSettings.default
        external.aiNotesEnabled = false
        try external.save(to: home.settingsFileURL)
        document.refreshFromDisk()
        #expect(!document.settings.aiNotesEnabled)
        #expect(!document.hasConflict)

        document.settings.transcriptFixerEnabled = false
        external.noteTitleEnabled = false
        try external.save(to: home.settingsFileURL)
        document.refreshFromDisk()
        #expect(document.hasConflict)
        #expect(try SimbiSettings.load(from: home.settingsFileURL) == external)

        document.overwriteDisk()
        #expect(!document.hasConflict)
        #expect(try SimbiSettings.load(from: home.settingsFileURL) == document.settings)
    }
}
