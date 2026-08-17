import AppKit
import CodexKit
import Foundation
import Observation
import SimbiKit
import SwiftUI

/// Live Codex-connection state for the welcome pane's setup card.
/// Polls two cheap file checks (the bundled binary and `~/.codex/auth.json`)
/// every 2 s while the pane is visible, so the card advances by itself as
/// the user installs the ChatGPT app and signs in. No subprocess, no
/// app-server probe — the same signals `CodexStatusFooter` trusts.
@MainActor
@Observable
final class CodexSetupModel {
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

    /// Run from the welcome pane's `.task` — cancellation on disappear
    /// stops the polling with it.
    func poll() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// One-shot, preview-aware state for surfaces that don't poll
    /// (the transcript pane's first-note hint).
    static func detectState() -> CodexSetupState {
        previewState()
            ?? CodexSetupState.resolve(
                isInstalled: CodexInstallation.standard.isBinaryInstalled,
                isSignedIn: CodexInstallation.standard.loadAuth() != nil)
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
