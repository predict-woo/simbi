import Foundation

/// The `~/Simbi` home directory: locating it, and first-launch bootstrap.
///
/// Everything Simbi knows lives in plain files under this root (SPEC.md §2.1).
/// `bootstrap()` is idempotent: it creates the directory, a default
/// `.simbi/settings.json`, and `AGENTS.md` — but never overwrites a file the
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
        if !fm.fileExists(atPath: agentsFileURL.path) {
            try Self.agentsFileContents.write(to: agentsFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Written to `~/Simbi/AGENTS.md` on first launch so any Codex thread
    /// opened at the home root understands the layout without per-thread
    /// boilerplate (SPEC.md §2.1).
    public static let agentsFileContents = """
        # Simbi home directory

        This directory is managed by **Simbi**, a macOS notetaking app that records,
        diarizes, and transcribes audio into plain files. There is no database:
        what you see on disk is the entire state.

        ## Layout

        - A folder containing `note.md` is a **note folder** — a single note. Note
          folders are never nested inside other note folders.
        - Folders without `note.md` are purely organizational.
        - `.simbi/` at this root holds app-global settings.

        ## Inside a note folder

        | Entry | Meaning |
        |---|---|
        | `note.md` | The user's own markdown note. |
        | `audio.webm` | The note's single continuous recording (WebM/Opus, all sessions appended). |
        | `transcript.vtt` | The WebVTT transcript of `audio.webm`. Rendered live by the app. |
        | `files/` | User-added input files. **Originals — never modify.** |
        | `context/` | Markdown conversions of `files/` entries (`<name>.md` mirrors `files/<name>`). |
        | `.simbi/` | Internal state (thread ids, job state, pending uploads). Do not edit by hand. |

        ## Rules for agents working here

        - Any edit to `transcript.vtt` must leave it **valid WebVTT** — the app renders
          it live. Never renumber cues, never change cue timestamps.
        - `NOTE session` blocks mark recording stop/resume boundaries. Speaker slot
          numbering may reshuffle across sessions; `<v>` speaker names may be unified
          across sessions only when the content makes identity unambiguous.
        - `NOTE gap` blocks mark silences that have audio but no transcript cue.
        - Never modify anything under `files/` or `.simbi/`.
        """
}
