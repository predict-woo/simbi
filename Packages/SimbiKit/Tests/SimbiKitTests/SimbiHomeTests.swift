import Foundation
import Testing

@testable import SimbiKit

@Suite("SimbiHome")
struct SimbiHomeTests {
    private func makeTempHome() throws -> SimbiHome {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        return SimbiHome(rootURL: root)
    }

    @Test("bootstrap creates root, instruction files, and default settings")
    func bootstrapCreatesWorld() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home.rootURL) }

        try home.bootstrap()

        #expect(FileManager.default.fileExists(atPath: home.rootURL.path))
        for file in AgentInstructions.allCases {
            let url = file.url(homeRootURL: home.rootURL)
            #expect(try String(contentsOf: url, encoding: .utf8) == file.defaultContents)
        }
        let settings = try SimbiSettings.load(from: home.settingsFileURL)
        #expect(settings == .default)
    }

    @Test("bootstrap never overwrites user-edited files")
    func bootstrapIsIdempotent() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home.rootURL) }

        try home.bootstrap()
        let agentsFileURL = AgentInstructions.agents.url(homeRootURL: home.rootURL)
        try "user edits".write(to: agentsFileURL, atomically: true, encoding: .utf8)
        var settings = SimbiSettings.default
        settings.transcriptFixerEnabled = false
        settings.aiNotesEnabled = false
        settings.noteTitleEnabled = false
        settings.fixerModel = "gpt-5.4"
        try settings.save(to: home.settingsFileURL)

        try home.bootstrap()

        #expect(try String(contentsOf: agentsFileURL, encoding: .utf8) == "user edits")
        #expect(try SimbiSettings.load(from: home.settingsFileURL) == settings)
    }
}

@Suite("SimbiHome override")
struct SimbiHomeOverrideTests {
    /// A throwaway defaults suite so tests never touch the app's real domain.
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "simbi-home-override-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test("resolves to the default root when no override is set")
    func noOverrideResolvesToDefault() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        #expect(SimbiHome.overrideRootURL(in: defaults) == nil)
        #expect(SimbiHome.resolvedRootURL(defaults: defaults) == SimbiHome.defaultRootURL)
    }

    @Test("a set override wins over the default root")
    func overrideWins() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let custom = URL(filePath: "/Users/someone/Notes/Simbi", directoryHint: .isDirectory)

        SimbiHome.setOverrideRootURL(custom, in: defaults)

        #expect(SimbiHome.overrideRootURL(in: defaults) == custom.standardizedFileURL)
        #expect(SimbiHome.resolvedRootURL(defaults: defaults) == custom.standardizedFileURL)
    }

    @Test("clearing the override reverts to the default root")
    func clearingReverts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        SimbiHome.setOverrideRootURL(
            URL(filePath: "/Users/someone/Elsewhere", directoryHint: .isDirectory), in: defaults)

        SimbiHome.setOverrideRootURL(nil, in: defaults)

        #expect(SimbiHome.overrideRootURL(in: defaults) == nil)
        #expect(SimbiHome.resolvedRootURL(defaults: defaults) == SimbiHome.defaultRootURL)
    }

    @Test("the override survives into a fresh defaults instance (persistence)")
    func overridePersists() throws {
        let suiteName = "simbi-home-override-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let custom = URL(filePath: "/Volumes/External/Simbi", directoryHint: .isDirectory)

        SimbiHome.setOverrideRootURL(custom, in: defaults)

        let reread = try #require(UserDefaults(suiteName: suiteName))
        #expect(SimbiHome.overrideRootURL(in: reread) == custom.standardizedFileURL)
    }

    @Test("activeRootURL latches for the process: later override edits don't move it")
    func activeRootLatches() throws {
        let latched = SimbiHome.activeRootURL

        SimbiHome.setOverrideRootURL(
            URL(filePath: "/Users/someone/Moved/Simbi", directoryHint: .isDirectory))
        defer { SimbiHome.setOverrideRootURL(nil) }

        #expect(SimbiHome.activeRootURL == latched)
        // Every fresh SimbiHome() stays on the latched root too.
        #expect(SimbiHome().rootURL == latched)
    }
}

@Suite("SimbiSettings")
struct SimbiSettingsTests {
    @Test("round-trips through disk")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var settings = SimbiSettings.default
        settings.fixerModel = "gpt-5.4"
        settings.summaryModel = "gpt-5.4-mini"
        settings.titleModel = "gpt-5.4-mini"
        settings.fixerEffort = "high"
        settings.converterEffort = "low"
        settings.summaryEffort = "medium"
        settings.titleEffort = "low"
        settings.systemAudioEnabled = false
        settings.micDeviceUID = "BuiltInMicrophoneDevice"
        try settings.save(to: url)

        #expect(try SimbiSettings.load(from: url) == settings)
    }

    @Test("missing keys decode to defaults (forward compatibility)")
    func missingKeysDefault() throws {
        let decoded = try JSONDecoder().decode(SimbiSettings.self, from: Data("{}".utf8))
        #expect(decoded == .default)
    }

    @Test("legacy audioSource key migrates to the split source fields")
    func legacyAudioSource() throws {
        let micOnly = try JSONDecoder().decode(
            SimbiSettings.self, from: Data(#"{"audioSource":"mic"}"#.utf8))
        #expect(micOnly.micEnabled && !micOnly.systemAudioEnabled)

        let both = try JSONDecoder().decode(
            SimbiSettings.self, from: Data(#"{"audioSource":"micAndSystem"}"#.utf8))
        #expect(both.micEnabled && both.systemAudioEnabled)
    }

    @Test("both sources disabled on disk re-enables the mic")
    func bothDisabledFallsBackToMic() throws {
        let decoded = try JSONDecoder().decode(
            SimbiSettings.self,
            from: Data(#"{"micEnabled":false,"systemAudioEnabled":false}"#.utf8))
        #expect(decoded.micEnabled)
    }
}
