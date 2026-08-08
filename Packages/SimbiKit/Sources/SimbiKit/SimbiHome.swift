import Foundation

/// The `~/Simbi` home directory: locating it, and first-launch bootstrap.
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

    public var settingsDirectoryURL: URL {
        rootURL.appending(path: ".simbi", directoryHint: .isDirectory)
    }

    public var settingsFileURL: URL {
        settingsDirectoryURL.appending(path: "settings.json")
    }

    public var agentsFileURL: URL {
        rootURL.appending(path: "AGENTS.md")
    }

    public init(rootURL: URL = SimbiHome.defaultRootURL) {
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
