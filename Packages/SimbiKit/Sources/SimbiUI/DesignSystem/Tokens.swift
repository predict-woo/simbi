import AppKit
import SimbiKit
import SwiftUI

/// SimbiUI's shared design language. `docs/design-system.md` is the
/// contract this namespace implements — every view draws type, spacing,
/// and color decisions from here so the panes read as one app.
enum Design {
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
    /// Active-tab underline in the editor tab strip.
    static let tabUnderlineHeight: CGFloat = 2

    /// The note editor's base point size (document canvas, not UI chrome).
    static let editorFontSize: CGFloat = 15

    // MARK: Variable tokens (instructions editor, AppKit attribute layer)

    /// Ink for `{{ variable }}` chips. System accent on purpose — the app
    /// has no custom accent, and the chip must read as "interactive-ish
    /// token", not a status hue.
    static let variableInk = NSColor.controlAccentColor
    /// Chip fill behind a variable, same 0.12 soft-tint convention as
    /// `speakerTint`.
    static let variableTint = NSColor.controlAccentColor.withAlphaComponent(0.12)

    // MARK: Geometry

    enum Radius {
        /// Tiny inline badges.
        static let badge: CGFloat = 3
        /// Row-level highlights (active transcript cue).
        static let row: CGFloat = 6
        /// Cards: inspector panels, setup card, drop targets.
        static let card: CGFloat = 8
    }

    // MARK: Motion

    enum Anim {
        /// Hover / drop-target feedback.
        static let quick = Animation.easeOut(duration: 0.15)
        /// State transitions, scroll-to-cue.
        static let standard = Animation.easeInOut(duration: 0.25)
    }

    // MARK: Speakers

    /// Speaker colors live on an OKLCH wheel: one lightness for every
    /// speaker (so no voice reads louder than another), hues spaced by the
    /// golden angle so any number of speakers stays maximally separated.
    /// The anchor hue is indigo. Each hue takes the target chroma, backing
    /// off to the sRGB gamut boundary only where it must (cyan, hue ≈ 200,
    /// is the bottleneck at this lightness) — vivid everywhere, grey
    /// nowhere.
    static let speakerLightness = 0.65
    static let speakerChromaTarget = 0.18
    private static let speakerBaseHue = 265.0
    private static let goldenAngle = 137.5

    static func speakerHue(slot: Int) -> Double {
        (speakerBaseHue + Double(slot) * goldenAngle).truncatingRemainder(dividingBy: 360)
    }

    static func speakerChroma(hue: Double) -> Double {
        min(speakerChromaTarget, OKLCH.maxChroma(lightness: speakerLightness, hue: hue))
    }

    static func speakerColor(slot: Int) -> Color {
        let hue = speakerHue(slot: slot)
        return OKLCH.color(
            lightness: speakerLightness, chroma: speakerChroma(hue: hue), hue: hue)
    }

    /// Soft fill for speaker capsules and the active-cue highlight.
    static func speakerTint(slot: Int) -> Color {
        speakerColor(slot: slot).opacity(0.12)
    }

    /// Wheel slots for a transcript's speakers: alphabetical (numeric-aware,
    /// so "Speaker 2" sorts before "Speaker 10"), duplicates collapsed.
    /// Purely positional — renaming a speaker may re-deal colors, but two
    /// distinct names can never collide on one hue.
    static func speakerSlots(names: some Sequence<String>) -> [String: Int] {
        let sorted = Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
    }

    // MARK: Time

    /// Compact human time for UI readouts: 0:07, 12:34, 1:02:03 — the
    /// same rendering AI-notes timestamp citations use, deliberately
    /// (`TimestampLink` owns it; `VTT.timestamp` is the wire format and
    /// never shows in UI).
    static func time(_ seconds: TimeInterval) -> String {
        TimestampLink.render(seconds)
    }
}
