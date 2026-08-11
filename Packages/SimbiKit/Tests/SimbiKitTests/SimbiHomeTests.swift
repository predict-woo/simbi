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
        try "user edits".write(to: home.agentsFileURL, atomically: true, encoding: .utf8)
        var settings = SimbiSettings.default
        settings.fixerModel = "gpt-5.4"
        try settings.save(to: home.settingsFileURL)

        try home.bootstrap()

        #expect(try String(contentsOf: home.agentsFileURL, encoding: .utf8) == "user edits")
        #expect(try SimbiSettings.load(from: home.settingsFileURL).fixerModel == "gpt-5.4")
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
