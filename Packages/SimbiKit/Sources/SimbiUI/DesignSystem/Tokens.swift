import SwiftUI

/// SimbiUI's shared design language. `docs/design-system.md` is the
/// contract this namespace implements — every view draws type, spacing,
/// and color decisions from here so the panes read as one app.
enum Design {
    /// Design-review mode: `SIMBI_UI_PREVIEW=1` forces the rare states
    /// (degraded banners, live-recording header, playback bar) visible so
    /// they can be screenshotted without recording or playing audio.
    /// Inert in normal launches.
    static let uiPreview = ProcessInfo.processInfo.environment["SIMBI_UI_PREVIEW"] == "1"

    // MARK: Spacing — 4pt grid

    /// Pane content inset (transcript, files, banners, chrome strips).
    static let paneInset: CGFloat = 16
    /// The editor canvas's text inset; the files strip aligns to it.
    static let editorInset: CGFloat = 24
    /// Horizontal inset for sidebar-footer rows (update pill, codex status).
    static let footerInset: CGFloat = 12
    /// Vertical rhythm between sibling rows in a pane.
    static let rowGap: CGFloat = 12
    /// Gap between a row's header line and its content line.
    static let innerGap: CGFloat = 3
    /// Gap between an icon/dot and its label.
    static let iconGap: CGFloat = 5
    /// Vertical padding of horizontal chrome strips (banners, playback
    /// bar, recording header, status rows).
    static let stripPadding: CGFloat = 8
    /// Denser vertical padding for sidebar-footer strips.
    static let footerStripPadding: CGFloat = 6
    /// Status and speaker identity dots, everywhere.
    static let dotSize: CGFloat = 7
    /// Files-shelf tile width (thumbnail box and caption).
    static let fileTileWidth: CGFloat = 88
    /// Files-shelf thumbnail box height.
    static let fileThumbHeight: CGFloat = 64

    /// The note editor's base point size (document canvas, not UI chrome).
    static let editorFontSize: CGFloat = 15

    // MARK: Geometry

    enum Radius {
        /// Tiny inline badges.
        static let badge: CGFloat = 3
        /// Row-level highlights (active transcript cue).
        static let row: CGFloat = 6
        /// Cards: inspector panels, setup card, drop targets.
        static let card: CGFloat = 8
        /// Floating overlays (terminal session-ended scrim).
        static let overlay: CGFloat = 12
    }

    // MARK: Motion

    enum Anim {
        /// Hover / drop-target feedback.
        static let quick = Animation.easeOut(duration: 0.15)
        /// State transitions, scroll-to-cue.
        static let standard = Animation.easeInOut(duration: 0.25)
    }

    // MARK: Speakers

    /// Speaker hues, softer than the default system rainbow (and none of
    /// them red — red belongs to the record control). Slot order is stable
    /// so "Speaker N" keeps its color across sessions.
    static let speakerPalette: [Color] = [.indigo, .teal, .orange, .purple]

    static func speakerColor(_ name: String) -> Color {
        if name.hasPrefix("Speaker "), let n = Int(name.dropFirst(8)), n >= 1 {
            return speakerPalette[(n - 1) % speakerPalette.count]
        }
        return speakerPalette[stableHash(name) % speakerPalette.count]
    }

    /// Soft fill for speaker capsules and the active-cue highlight.
    static func speakerTint(_ name: String) -> Color {
        speakerColor(name).opacity(0.12)
    }

    /// Deterministic string hash (djb2). `String.hashValue` is seeded per
    /// process, which made renamed speakers change color on every launch.
    private static func stableHash(_ string: String) -> Int {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }

    // MARK: Time

    /// Compact human time for UI readouts: 0:07, 12:34, 1:02:03.
    /// (`VTT.timestamp` is the wire format — never show it in UI.)
    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins, secs)
            : String(format: "%d:%02d", mins, secs)
    }
}
