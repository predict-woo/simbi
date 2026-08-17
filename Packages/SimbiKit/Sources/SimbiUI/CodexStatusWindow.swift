import AppKit
import CodexKit
import Observation
import SimbiKit
import SwiftUI

/// Account, plan, and remaining usage for the signed-in Codex account
/// (2026-08-12 status-window spec). Reloaded on every window open and
/// from the refresh button; degraded states mirror the app's usual
/// messaging — never an error dialog.
@MainActor
@Observable
final class CodexStatusModel {
    enum Phase {
        case loading
        case loaded(CodexAccountStatus)
        case unavailable(String)
    }

    private(set) var phase: Phase = .loading
    private var loadTask: Task<Void, Never>?

    func reload() {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task {
            switch CodexSetupModel.shared.state {
            case .notInstalled:
                phase = .unavailable("Codex is unavailable. Is the ChatGPT app installed?")
                return
            case .signedOut:
                phase = .unavailable("Sign in to the ChatGPT app to connect Codex.")
                return
            case .connected:
                break
            }
            do {
                let status = try await CodexAccountStatus.fetch(client: CodexServices.appServer)
                guard !Task.isCancelled else { return }
                phase = .loaded(status)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .unavailable("Codex did not answer. Try again in a moment.")
            }
        }
    }
}

/// One shared status window, opened from the sidebar footer. Plain AppKit
/// window like the instructions editors: the manager keeps the strong
/// reference, no restoration, no tabbing.
@MainActor
public final class CodexStatusWindowManager {
    public static let shared = CodexStatusWindowManager()

    private var window: NSWindow?
    private let model = CodexStatusModel()

    public func open() {
        model.reload()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Codex Status"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: CodexStatusView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct CodexStatusView: View {
    let model: CodexStatusModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Design.paneInset * 2)
            case .unavailable(let message):
                HStack(spacing: Design.iconGap) {
                    StatusDot(color: .statusWarning)
                    Text(message)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Design.paneInset)
            case .loaded(let status):
                content(status)
            }
        }
        .padding(Design.paneInset)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func content(_ status: CodexAccountStatus) -> some View {
        VStack(alignment: .leading, spacing: Design.rowGap) {
            HStack(alignment: .firstTextBaseline, spacing: Design.iconGap) {
                StatusDot(color: .statusOK)
                VStack(alignment: .leading, spacing: Design.innerGap) {
                    Text(status.account?.email ?? "Signed in")
                        .font(.body)
                    if let plan = status.account?.planType {
                        Text("\(plan.capitalized) plan")
                            .font(.meta)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(HoverCircleButtonStyle())
                .help("Refresh")
            }
            SectionLabel(title: "Usage")
            VStack(alignment: .leading, spacing: Design.rowGap) {
                ForEach(status.limits) { limit in
                    limitRow(limit)
                    if limit.id != status.limits.last?.id {
                        Hairline()
                    }
                }
            }
            .padding(Design.rowGap)
            .card()
            if status.resetCreditsAvailable > 0 {
                HStack(spacing: Design.iconGap) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.meta)
                    Text(
                        status.resetCreditsAvailable == 1
                            ? "1 rate-limit reset available"
                            : "\(status.resetCreditsAvailable) rate-limit resets available"
                    )
                    .font(.meta)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func limitRow(_ limit: CodexAccountStatus.RateLimitWindow) -> some View {
        VStack(alignment: .leading, spacing: Design.innerGap) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.displayName)
                    .font(.body)
                Spacer()
                Text("\(Int(limit.usedPercent.rounded()))%")
                    .font(.metaMono)
                    .foregroundStyle(.secondary)
            }
            MeterBar(
                fraction: limit.usedPercent / 100,
                // The one warning hue once a window runs low; accent
                // (system blue) otherwise.
                tint: limit.usedPercent >= 75 ? .statusWarning : .accentColor
            )
            .padding(.vertical, Design.innerGap)
            if let caption = windowCaption(limit) {
                Text(caption)
                    .font(.meta)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// "weekly limit · resets Aug 18" (parts drop out when unknown).
    private func windowCaption(_ limit: CodexAccountStatus.RateLimitWindow) -> String? {
        var parts: [String] = []
        if let label = limit.windowLabel {
            parts.append("\(label) limit")
        }
        if let resetsAt = limit.resetsAt {
            parts.append(
                "resets " + resetsAt.formatted(.dateTime.month(.abbreviated).day()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
