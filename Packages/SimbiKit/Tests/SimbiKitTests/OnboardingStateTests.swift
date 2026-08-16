import Foundation
import Testing

@testable import SimbiKit

@Suite struct OnboardingStateTests {
    /// Fresh defaults per test so state never leaks between tests.
    private func makeDefaults() -> UserDefaults {
        let name = "onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func neededUntilMarkedCompleted() {
        let defaults = makeDefaults()
        #expect(OnboardingState.isNeeded(defaults: defaults))
        OnboardingState.markCompleted(defaults: defaults)
        #expect(!OnboardingState.isNeeded(defaults: defaults))
        #expect(
            defaults.integer(forKey: OnboardingState.completedVersionDefaultsKey)
                == OnboardingState.currentVersion)
    }

    @Test func staleVersionCountsAsNeeded() {
        let defaults = makeDefaults()
        defaults.set(
            OnboardingState.currentVersion - 1,
            forKey: OnboardingState.completedVersionDefaultsKey)
        #expect(OnboardingState.isNeeded(defaults: defaults))
    }

    @Test func applyBootstrapsChosenRootAndMergesModels() throws {
        let defaults = makeDefaults()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "onboarding-apply-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        var draft = OnboardingState.Draft(rootURL: root)
        draft.fixerModel = "gpt-5.2-codex"
        draft.summaryEffort = "high"
        try OnboardingState.apply(draft, defaults: defaults)

        // Non-default root persisted as the override.
        #expect(SimbiHome.overrideRootURL(in: defaults) == root.standardizedFileURL)
        // Home bootstrapped and the draft merged into settings.
        let home = SimbiHome(rootURL: root)
        let saved = try SimbiSettings.load(from: home.settingsFileURL)
        #expect(saved.fixerModel == "gpt-5.2-codex")
        #expect(saved.summaryEffort == "high")
        // Untouched fields keep their defaults.
        #expect(saved.micEnabled && saved.systemAudioEnabled)
    }

    @Test func defaultRootClearsOverrideInsteadOfWritingIt() {
        let defaults = makeDefaults()
        SimbiHome.setOverrideRootURL(
            FileManager.default.temporaryDirectory.appending(path: "stale"), in: defaults)
        OnboardingState.persistRootOverride(SimbiHome.defaultRootURL, defaults: defaults)
        #expect(SimbiHome.overrideRootURL(in: defaults) == nil)
    }
}
