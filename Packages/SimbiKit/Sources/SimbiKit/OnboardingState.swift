import Foundation

/// First-run onboarding persistence
/// (docs/superpowers/specs/2026-08-17-onboarding-wizard-design.md): the
/// completion flag and the atomic apply that turns the wizard's draft into
/// real state. The flag is a UserDefaults sibling of `homeRootPath`,
/// outside the notes folder on purpose: it must be readable before a
/// folder exists.
public enum OnboardingState {
    /// Bump to re-show onboarding after a breaking setup change.
    public static let currentVersion = 1
    public static let completedVersionDefaultsKey = "onboardingCompletedVersion"

    public static func isNeeded(defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: completedVersionDefaultsKey) < currentVersion
    }

    public static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: completedVersionDefaultsKey)
    }

    /// The wizard's collected choices. Nothing is persisted while the
    /// wizard runs; `apply(_:)` lands everything in one place so quitting
    /// mid-wizard leaves no app state behind.
    public struct Draft: Sendable, Equatable {
        public var rootURL: URL
        /// Per-role model/effort choices; absent roles read as "Default".
        public var choices: [AgentRole: ModelChoice] = [:]

        public init(rootURL: URL = SimbiHome.defaultRootURL) {
            self.rootURL = rootURL
        }

        public subscript(role: AgentRole) -> ModelChoice {
            get { choices[role] ?? ModelChoice() }
            set { choices[role] = newValue }
        }
    }

    /// Persist the root override (cleared when the draft kept the
    /// default), bootstrap the home, and merge the draft's model choices
    /// into settings. Throws before the completion flag would be set; the
    /// caller marks completion only after this succeeds.
    public static func apply(_ draft: Draft, defaults: UserDefaults = .standard) throws {
        persistRootOverride(draft.rootURL, defaults: defaults)
        let home = SimbiHome(rootURL: draft.rootURL)
        try home.bootstrap()
        var settings = (try? SimbiSettings.load(from: home.settingsFileURL)) ?? .default
        for role in AgentRole.allCases {
            settings[role] = draft[role]
        }
        try settings.save(to: home.settingsFileURL)
    }

    /// Writes the override only for a non-default root; a default choice
    /// clears any stale override instead.
    static func persistRootOverride(_ rootURL: URL, defaults: UserDefaults) {
        let isDefault =
            rootURL.standardizedFileURL == SimbiHome.defaultRootURL.standardizedFileURL
        SimbiHome.setOverrideRootURL(isDefault ? nil : rootURL, in: defaults)
    }
}
