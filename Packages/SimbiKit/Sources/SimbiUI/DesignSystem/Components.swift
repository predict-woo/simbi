import SwiftUI

/// Shared components (docs/design-system.md § Components). A pattern
/// earns a slot here on its third occurrence — one-offs stay inline.

/// Section label — "Files", inspector section headers.
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.metaSemibold)
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

/// Protects a dirty editor when another process changes its file. Clean
/// editors reload silently; this appears only when choosing either side is
/// necessarily destructive.
struct FileConflictBanner: View {
    let fileName: String
    let reload: () -> Void
    let overwrite: () -> Void

    init(document: AutosavingDocument) {
        self.fileName = document.fileURL.lastPathComponent
        self.reload = document.reloadFromDisk
        self.overwrite = document.overwriteDisk
    }

    init(
        fileName: String, reload: @escaping () -> Void,
        overwrite: @escaping () -> Void
    ) {
        self.fileName = fileName
        self.reload = reload
        self.overwrite = overwrite
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.meta)
            Text("\(fileName) changed on disk.")
                .font(.meta)
            Spacer(minLength: 0)
            Button("Reload") {
                reload()
            }
            Button("Overwrite") {
                overwrite()
            }
        }
        .buttonStyle(.link)
        .font(.metaSemibold)
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
    let color: Color

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

/// Status hue dot, optionally with a meta label — the connected /
/// unavailable / live indicator (sidebar footer, welcome card, recording
/// header, inspector status row).
struct StatusDot: View {
    let color: Color
    var label: String?

    var body: some View {
        HStack(spacing: Design.iconGap) {
            Circle()
                .fill(color)
                .frame(width: Design.dotSize, height: Design.dotSize)
            if let label {
                Text(label)
                    .font(.meta)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 1pt rule — the only divider besides stock `Divider()` in stock lists.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.hairline).frame(height: 1)
    }
}

/// Capsule meter: `trackFill` track with a tinted fill from the left.
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.trackFill)
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

extension View {
    /// The Rename dialog shared by the toolbar-title click and the
    /// sidebar's context menu: a name field, Rename (ignored while
    /// empty), Cancel.
    func renameAlert(
        isPresented: Binding<Bool>, name: Binding<String>,
        onRename: @escaping (String) -> Void
    ) -> some View {
        alert("Rename", isPresented: isPresented) {
            TextField("Name", text: name)
            Button("Rename") {
                if !name.wrappedValue.isEmpty {
                    onRename(name.wrappedValue)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Floating-element chrome (docs/design-system.md § Components):
    /// Liquid Glass where the OS has it (macOS 26); further back, the
    /// closest material plus a hairline stroke and a soft drop shadow so
    /// the element still separates from content scrolling beneath it.
    @ViewBuilder func floatingChrome(in shape: some InsettableShape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background {
                shape
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
                shape.strokeBorder(Color.hairline)
            }
        }
    }
}

/// Display hero — 44 pt light symbol, title, secondary subtitle — the
/// shared header of the welcome pane and every onboarding step. Emitted
/// as a Group so the parent stack owns the spacing.
struct HeroHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        Group {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
