import SimbiKit
import SwiftUI

/// The whole of Simbi's update nagging: one quiet row in the sidebar footer.
///
/// Sparkle's own scheduled-update alert is suppressed (the app shell's
/// coordinator declares gentle-reminder support), so this is the only thing
/// that ever asks. It disappears entirely while recording — see `UpdateGate`.
struct UpdatePill: View {
    @Bindable var model: UpdateModel

    var body: some View {
        switch model.presentation {
        case .hidden:
            EmptyView()
        case .available(let version):
            pill(
                "Update to \(version)",
                icon: "arrow.down.circle",
                action: { model.checkForUpdates() })
        case .readyToInstall(let version):
            pill(
                "Restart to update to \(version)",
                icon: "arrow.up.circle.fill",
                action: { model.installUpdate() })
        case .waitingForRecordingToEnd(let version):
            // Reassurance, not an invitation: no button, nothing to click
            // wrong while a meeting is being captured.
            HStack(spacing: Design.iconGap) {
                Image(systemName: "clock")
                    .font(.meta)
                Text("Simbi \(version) installs after this recording")
                    .font(.meta)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.footerInset)
            .padding(.vertical, Design.footerStripPadding)
        }
    }

    private func pill(
        _ title: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Design.iconGap) {
                Image(systemName: icon)
                    .font(.meta)
                Text(title)
                    .font(.metaSemibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Design.footerInset)
            .padding(.vertical, Design.footerStripPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
