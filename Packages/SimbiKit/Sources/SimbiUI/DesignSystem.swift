import SwiftUI

/// SimbiUI's shared design language. Every view draws type, spacing, and
/// color decisions from here so the panes read as one app.
///
/// Type scale (system font throughout):
///   - `.body` (13) — all UI prose: transcript cues, file names, form rows
///   - `.editorBody` (15) — the note editor's document canvas only
///   - `.meta` (11) — timestamps, speaker names, status words
///   - section labels — 11 semibold, uppercased with tracking, secondary
///
/// Spacing: 4pt grid. Pane insets 16, list row gap 12, intra-row gap 3.
enum Design {
    /// Design-review mode: `SIMBI_UI_PREVIEW=1` forces the rare states
    /// (degraded banners, live-recording header, playback bar) visible so
    /// they can be screenshotted without recording or playing audio.
    /// Inert in normal launches.
    static let uiPreview = ProcessInfo.processInfo.environment["SIMBI_UI_PREVIEW"] == "1"

    /// Pane content inset (transcript, files, banners).
    static let paneInset: CGFloat = 16
    /// Vertical rhythm between sibling rows in a pane.
    static let rowGap: CGFloat = 12
    /// Gap between a row's header line and its content line.
    static let innerGap: CGFloat = 3

    /// The note editor's base point size (document canvas, not UI chrome).
    static let editorFontSize: CGFloat = 15

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

    /// Deterministic string hash (djb2). `String.hashValue` is seeded per
    /// process, which made renamed speakers change color on every launch.
    private static func stableHash(_ string: String) -> Int {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }

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

extension Font {
    /// Metadata: timestamps, speaker names, inline status words.
    static let meta = Font.system(size: 11)
    /// Emphasized metadata (speaker names, banner text).
    static let metaSemibold = Font.system(size: 11, weight: .semibold)
}

/// Uppercased, tracked section label — "FILES", "TRANSCRIPT".
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }
}

/// The one warning style: soft tinted strip with an icon, used for every
/// degraded state (Codex missing, system audio denied, transcript invalid).
struct StatusBanner: View {
    let message: String
    var icon: String = "exclamationmark.triangle.fill"
    /// Trailing action, e.g. an "Open System Settings" link.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.meta)
            Text(message)
                .font(.meta)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.metaSemibold)
            }
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
    }
}

/// Colored identity dot + name — the speaker treatment shared by the
/// transcript rows and the recording header's live indicator.
struct SpeakerChip: View {
    let name: String
    var color: Color { Design.speakerColor(name) }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.metaSemibold)
                .foregroundStyle(color)
        }
    }
}
