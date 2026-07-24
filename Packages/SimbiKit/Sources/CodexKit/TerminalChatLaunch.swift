import Foundation

/// Launch spec for the per-note chat terminal: the embedded Ghostty surface
/// runs the packaged codex TUI directly, so codex owns the whole
/// conversational UI (composer, streaming, approvals) and Simbi only hosts
/// the terminal.
///
/// The command line is one constant string; everything per-note travels in
/// environment variables that the shell expands at spawn time. That keeps
/// note titles, paths, and the context blurb out of shell-quoting territory
/// entirely.
public struct TerminalChatLaunch: Sendable, Equatable {
    /// Ghostty runs this via `bash -c "exec -l <command>"` (`command =`
    /// config key), with two parsing traps verified against Ghostty 1.3:
    /// it prepends the `exec` itself (a leading `exec` here becomes
    /// `exec exec` and fails), and it strips a matching pair of
    /// surrounding double quotes from the config value — so the string
    /// must neither start nor end with `"`. $SIMBI_CODEX_BIN stays
    /// unquoted (the ChatGPT.app path has no spaces); the dir and context
    /// vars keep their quotes.
    ///
    /// Flags mirror the retired app-server chat: workspace-write sandbox,
    /// on-request approvals, the whole Simbi home writable. Note context
    /// is injected as a developer message; a `-c` value that fails TOML
    /// parsing is taken as a literal string (codex --help), so no
    /// escaping is needed.
    public static let commandLine =
        "$SIMBI_CODEX_BIN -C \"$SIMBI_NOTE_DIR\" --add-dir \"$SIMBI_HOME_ROOT\" "
        + "-c developer_instructions=\"$SIMBI_CHAT_CONTEXT\" "
        + "-s workspace-write -a on-request"

    public let envVars: [String: String]

    public static func forNote(
        noteFolderURL: URL,
        homeRootURL: URL,
        installation: CodexInstallation = .standard
    ) -> TerminalChatLaunch {
        TerminalChatLaunch(envVars: [
            // Without CODEX_HOME the standalone binary uses a private home
            // invisible to the ChatGPT app login (CodexInstallation).
            "CODEX_HOME": installation.codexHomeURL.path,
            "SIMBI_CODEX_BIN": installation.binaryURL.path,
            "SIMBI_NOTE_DIR": noteFolderURL.standardizedFileURL.path,
            "SIMBI_HOME_ROOT": homeRootURL.standardizedFileURL.path,
            "SIMBI_CHAT_CONTEXT": developerInstructions(
                noteFolderURL: noteFolderURL, homeRootURL: homeRootURL),
        ])
    }

    /// The developer message codex starts with: what this folder is and
    /// which files it currently holds — names only, never contents. Codex
    /// reads what it needs itself, which also keeps long transcripts from
    /// pre-eating the context window the way the old inline-attachment
    /// prompt did.
    static func developerInstructions(noteFolderURL: URL, homeRootURL: URL) -> String {
        let notePath = CodexChat.notePath(
            noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        let files = inventory(noteFolderURL: noteFolderURL)
        let layout = """
            This session is attached to the Simbi note at `\(notePath)` (your working \
            directory). Simbi notes keep a fixed layout: `note.md` is the user's note, \
            `transcript.vtt` is the meeting transcript with speaker labels, `context/` \
            holds markdown conversions of attached files, and `files/` holds the \
            original attachments.
            """
        let contents =
            files.isEmpty
            ? "The note has no files yet."
            : "The note currently contains: " + files.map { "`\($0)`" }.joined(separator: ", ")
                + "."
        return """
            \(layout)

            \(contents)

            Read whichever files are relevant before answering, and when the user asks \
            for changes, edit the files on disk.
            """
    }

    /// Top-level note files plus one level of `context/` and `files/`,
    /// sorted for stable output.
    private static func inventory(noteFolderURL: URL) -> [String] {
        let fm = FileManager.default
        func names(in dir: URL, prefix: String = "") -> [String] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]))
                ?? [])
                .filter { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
                .map { prefix + $0.lastPathComponent }
        }
        let top = names(in: noteFolderURL)
        let context = names(in: noteFolderURL.appending(path: "context"), prefix: "context/")
        let attachments = names(in: noteFolderURL.appending(path: "files"), prefix: "files/")
        return (top + context + attachments).sorted()
    }
}
