import Foundation

/// Launch spec for the conversion-thread viewer terminal: the codex TUI
/// attaches as another client of the app's own app-server (`--remote`) and
/// resumes the conversion thread, so the user watches — and can interrupt
/// or continue — the live thread the app drives
/// (references/codex-remote-tui/README.md). Same env-var-only quoting
/// strategy and Ghostty parsing traps as TerminalChatLaunch.
public struct TerminalViewerLaunch: Sendable, Equatable {
    /// Must not begin with `exec` (Ghostty prepends its own) and must not
    /// start or end with a double quote (Ghostty strips a surrounding
    /// pair) — which is why $SIMBI_THREAD_ID stays unquoted at the end
    /// (thread ids are UUIDs, never containing spaces). `--remote` sits
    /// before the subcommand — the placement the research verified.
    public static let commandLine =
        "$SIMBI_CODEX_BIN --remote \"$SIMBI_APPSERVER_URL\" resume $SIMBI_THREAD_ID"

    public let envVars: [String: String]

    public static func forThread(
        threadId: String,
        appServerURL: String,
        installation: CodexInstallation = .standard
    ) -> TerminalViewerLaunch {
        TerminalViewerLaunch(
            envVars: installation.terminalLaunchEnvironment.merging([
                "SIMBI_APPSERVER_URL": appServerURL,
                "SIMBI_THREAD_ID": threadId,
            ]) { _, new in new })
    }
}
