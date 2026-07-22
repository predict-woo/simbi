import Foundation

/// The first-run Codex setup ladder shown by the welcome pane
/// (docs/superpowers/specs/2026-07-23-first-run-onboarding-design.md).
/// Resolves from the same signals the sidebar footer trusts — the bundled
/// binary and `~/.codex/auth.json` — no subprocess, no app-server probe.
/// Raw values match the `SIMBI_UI_PREVIEW_CODEX` screenshot override.
public enum CodexSetupState: String, Equatable, Sendable {
    /// ChatGPT.app binary absent.
    case notInstalled
    /// Binary present, `auth.json` missing or not a ChatGPT login.
    case signedOut
    /// Binary present and credentials load.
    case connected

    public static func resolve(isInstalled: Bool, isSignedIn: Bool) -> CodexSetupState {
        guard isInstalled else { return .notInstalled }
        return isSignedIn ? .connected : .signedOut
    }
}
