import Foundation

/// Every debug/preview environment flag the app understands, in one
/// place. All are read once at process start; unset or malformed
/// values mean "off". Add new flags here, never as inline
/// `ProcessInfo` reads in views or models.
public enum Flags {
    /// `SIMBI_UI_PREVIEW=1` — design-review mode: forces the rare UI
    /// states (degraded banners, live-recording header, playback bar)
    /// visible so they can be screenshotted without recording or
    /// playing audio. Master switch for every `uiPreview*` sub-flag
    /// below. Inert in normal launches.
    public static let uiPreview = environment["SIMBI_UI_PREVIEW"] == "1"

    /// `SIMBI_UI_PREVIEW_WELCOME=1` — forces the first-run welcome
    /// pane (WelcomeView) into the detail area even when the library
    /// has notes, as long as no note is open. Composes with
    /// `SIMBI_UI_PREVIEW_CODEX` to force each setup-card state.
    public static let uiPreviewWelcome =
        uiPreview && environment["SIMBI_UI_PREVIEW_WELCOME"] == "1"

    /// `SIMBI_UI_PREVIEW_SUMMARY=loading` — forces the AI Notes
    /// first-generation placeholder for design review.
    public static let uiPreviewSummaryLoading =
        uiPreview && environment["SIMBI_UI_PREVIEW_SUMMARY"] == "loading"

    /// `SIMBI_UI_PREVIEW_CODEX=notInstalled|signedOut|connected` —
    /// raw value forcing a Codex setup-card state without touching
    /// the real ChatGPT install. Parsed by `CodexSetupModel`.
    public static let uiPreviewCodex: String? =
        uiPreview ? environment["SIMBI_UI_PREVIEW_CODEX"] : nil

    /// `SIMBI_UI_PREVIEW_ONBOARDING=1` — forces the first-run onboarding
    /// wizard with faked permission, Codex, and download states so every
    /// step can be design-reviewed without touching TCC or the network.
    /// Composes with `SIMBI_UI_PREVIEW_CODEX` for the Codex step.
    public static let uiPreviewOnboarding =
        uiPreview && environment["SIMBI_UI_PREVIEW_ONBOARDING"] == "1"

    /// `SIMBI_NO_SPARKLE` (any value) — skips Sparkle startup for
    /// headless verification runs: its failed-check alert is
    /// app-modal and stalls the whole scene layer.
    public static let noSparkle = environment["SIMBI_NO_SPARKLE"] != nil

    private static let environment = ProcessInfo.processInfo.environment
}
