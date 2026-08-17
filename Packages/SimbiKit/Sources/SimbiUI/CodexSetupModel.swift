import AppKit
import CodexKit
import Foundation
import Observation
import SimbiKit
import SwiftUI

/// The app's one live source of Codex-connection truth (SPEC.md §6).
/// Polls two cheap file checks (the bundled binary and `~/.codex/auth.json`)
/// every 2 s, so every surface that observes `shared.state` — welcome card,
/// onboarding, degraded banners, sidebar footer, the auto-summary/-title
/// gates — advances by itself as the user installs the ChatGPT app and
/// signs in. No subprocess, no app-server probe.
@MainActor
@Observable
final class CodexSetupModel {
    /// The app-wide instance; its poll loop runs for the process lifetime.
    /// Direct `CodexSetupModel()` construction is for tests only.
    static let shared: CodexSetupModel = {
        let model = CodexSetupModel()
        Task { await model.poll() }
        return model
    }()

    private(set) var state: CodexSetupState

    private let isInstalled: () -> Bool
    private let isSignedIn: () -> Bool

    init(
        isInstalled: @escaping () -> Bool = {
            CodexInstallation.standard.isBinaryInstalled
        },
        isSignedIn: @escaping () -> Bool = {
            CodexInstallation.standard.loadAuth() != nil
        }
    ) {
        self.isInstalled = isInstalled
        self.isSignedIn = isSignedIn
        state =
            Self.previewState()
            ?? CodexSetupState.resolve(isInstalled: isInstalled(), isSignedIn: isSignedIn())
    }

    func refresh() {
        if let forced = Self.previewState() {
            state = forced
            return
        }
        state = CodexSetupState.resolve(isInstalled: isInstalled(), isSignedIn: isSignedIn())
    }

    private func poll() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Screenshot mode: `SIMBI_UI_PREVIEW=1` plus
    /// `SIMBI_UI_PREVIEW_CODEX=notInstalled|signedOut|connected` forces a
    /// card state without touching the real ChatGPT install.
    private static func previewState() -> CodexSetupState? {
        guard let raw = Flags.uiPreviewCodex else { return nil }
        return CodexSetupState(rawValue: raw)
    }
}

/// The setup state's one call to action — Get ChatGPT (the download page)
/// or Open ChatGPT — shared by the welcome pane's card and the onboarding
/// Codex step; nothing once connected. Callers style it (`buttonStyle`,
/// `tint`) to fit their surface.
struct CodexSetupActionButton: View {
    let state: CodexSetupState

    var body: some View {
        switch state {
        case .notInstalled:
            Button("Get ChatGPT") {
                NSWorkspace.shared.open(CodexInstallation.downloadURL)
            }
        case .signedOut:
            Button("Open ChatGPT") {
                NSWorkspace.shared.open(CodexInstallation.standard.appBundleURL)
            }
        case .connected:
            EmptyView()
        }
    }
}
