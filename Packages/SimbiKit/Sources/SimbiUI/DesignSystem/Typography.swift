import SwiftUI

/// The type scale (docs/design-system.md § Typography). System font only;
/// `.body` (13) is the UI-prose tier and needs no token. A new point size
/// is a design-language change, not a local decision.
extension Font {
    /// Metadata: timestamps, speaker names, inline status words, hints.
    static let meta = Font.system(size: 11)
    /// Emphasized metadata (speaker names, banner text, section labels).
    static let metaSemibold = Font.system(size: 11, weight: .semibold)
    /// Metadata that ticks — timers, counters. Digits align as they change.
    static let metaMono = Font.system(size: 11).monospacedDigit()
    /// Dense diagnostics: Pipeline Inspector tier, transcript gap markers.
    static let micro = Font.system(size: 10)
    /// Emphasized micro.
    static let microSemibold = Font.system(size: 10, weight: .semibold)
    /// Smallest tier: inspector canvas/axis labels only.
    static let canvasLabel = Font.system(size: 9)
}
