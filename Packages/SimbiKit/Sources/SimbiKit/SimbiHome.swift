import Foundation

/// The Simbi home directory (`~/Simbi` unless the user picked another folder
/// in Settings): locating it, and first-launch bootstrap.
///
/// Everything Simbi knows lives in plain files under this root (SPEC.md §2.1).
/// `bootstrap()` is idempotent: it creates the directory, a default
/// `.simbi/settings.json`, and the agent instruction files (`AGENTS.md`,
/// `FIXER.md`, `INGEST.md`, `CHAT.md`) — but never overwrites a file the
/// user (or an agent) has since edited.
public struct SimbiHome: Sendable, Equatable {
    public let rootURL: URL

    /// `~/Simbi` for the current user.
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Simbi", directoryHint: .isDirectory)
    }

    /// UserDefaults key holding the user-chosen home root path. It lives
    /// outside the home folder on purpose: the pointer must survive the
    /// folder it points to being switched away from.
    public static let overrideRootDefaultsKey = "homeRootPath"

    /// The user-chosen home root, or nil when the default applies.
    public static func overrideRootURL(in defaults: UserDefaults = .standard) -> URL? {
        defaults.string(forKey: overrideRootDefaultsKey)
            .map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
    }

    /// Persists (or, with nil, clears) the user-chosen home root.
    public static func setOverrideRootURL(_ url: URL?, in defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: overrideRootDefaultsKey)
        } else {
            defaults.removeObject(forKey: overrideRootDefaultsKey)
        }
    }

    /// `overrideRootURL` if set, else `defaultRootURL` — as stored right now.
    public static func resolvedRootURL(defaults: UserDefaults = .standard) -> URL {
        overrideRootURL(in: defaults) ?? defaultRootURL
    }

    /// The root this process runs against, latched on first access. A home
    /// switch saved while the app is running must NOT re-root live components
    /// mid-flight (watcher, recordings, settings saves) — it takes effect on
    /// relaunch, when the latch resolves the stored override afresh.
    public static let activeRootURL: URL = resolvedRootURL()

    public var settingsDirectoryURL: URL {
        rootURL.appending(path: NoteLayout.stateDirName, directoryHint: .isDirectory)
    }

    public var settingsFileURL: URL {
        settingsDirectoryURL.appending(path: "settings.json")
    }

    public init(rootURL: URL = SimbiHome.activeRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// Creates the home directory and its first-launch contents if missing.
    public func bootstrap() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: settingsDirectoryURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: settingsFileURL.path) {
            try SimbiSettings.default.save(to: settingsFileURL)
        }
        // Agent instruction files (SPEC.md §2.1): defaults on first launch,
        // then the user's — an existing file, however edited, is never
        // touched.
        for file in AgentInstructions.allCases {
            let url = file.url(homeRootURL: rootURL)
            if !fm.fileExists(atPath: url.path) {
                try file.defaultContents.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
