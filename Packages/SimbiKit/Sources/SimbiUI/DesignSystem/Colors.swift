import SwiftUI

/// The owned color vocabulary (docs/design-system.md § Color). Everything
/// else in SimbiUI is a hierarchical style (`.primary`/`.secondary`/…) or
/// a stock material — never a fixed gray, never hex.
extension Color {
    // MARK: Status hues

    /// Recording/live state and failures. Red belongs to the record
    /// control — never use it for anything that isn't live-or-broken.
    static let statusLive = Color.red
    /// Every degraded state: banners, unavailable dot, staging accents.
    static let statusWarning = Color.orange
    /// Connected/healthy — status dots only, never text.
    static let statusOK = Color.green

    // MARK: Surfaces

    /// Card and setup-card surfaces.
    static let cardFill = Color.primary.opacity(0.045)
    /// Meter tracks, drop-target idle fill.
    static let trackFill = Color.primary.opacity(0.06)
    /// Icon-selection backplate (files shelf), matching Finder's.
    static let selectionBackplate = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    /// Icon-button hover highlight (shelf add button).
    static let hoverFill = Color.primary.opacity(0.08)
    /// Icon-button pressed highlight — one step past hover.
    static let pressFill = Color.primary.opacity(0.14)
    /// 1pt rules and card strokes.
    static let hairline = Color(nsColor: .separatorColor)
    /// Recessed content wells (timeline, event log) — the text-view
    /// surface, so lane colors read on it in both appearances.
    static let well = Color(nsColor: .textBackgroundColor)
    /// Concrete tertiary ink for `Canvas`/AppKit contexts that can't take
    /// the hierarchical `.tertiary` style.
    static let faintInk = Color(nsColor: .tertiaryLabelColor)
}
