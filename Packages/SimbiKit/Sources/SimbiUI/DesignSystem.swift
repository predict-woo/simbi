import SwiftUI

/// Shared components of the design language. Tokens live in
/// `DesignSystem/{Tokens,Colors,Typography}.swift`; the contract is
/// `docs/design-system.md`.

/// Uppercased, tracked section label — "FILES", "TRANSCRIPT".
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.metaSemibold)
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
        .foregroundStyle(Color.statusWarning)
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, Design.stripPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.statusWarning.opacity(0.1))
    }
}

/// Colored identity dot + name — the speaker treatment shared by the
/// transcript rows and the recording header's live indicator.
struct SpeakerChip: View {
    let name: String
    var color: Color { Design.speakerColor(name) }

    var body: some View {
        HStack(spacing: Design.iconGap) {
            Circle()
                .fill(color)
                .frame(width: Design.dotSize, height: Design.dotSize)
            Text(name)
                .font(.metaSemibold)
                .foregroundStyle(color)
        }
    }
}
