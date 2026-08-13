import AppKit
import CodexKit
import SimbiKit
import SwiftUI

/// First-run welcome pane, shown in the detail area whenever the library
/// has zero notes (spec: 2026-07-23-first-run-onboarding-design.md).
/// No stored state — it disappears the moment a note exists and returns
/// only if the library is ever empty again.
/// `SIMBI_UI_PREVIEW=1 SIMBI_UI_PREVIEW_WELCOME=1` forces it for design
/// review regardless of library contents (see SimbiKit's `Flags`).
struct WelcomeView: View {
    @State private var setup = CodexSetupModel()
    let createNote: () -> Void

    var body: some View {
        VStack(spacing: Design.rowGap) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Welcome to Simbi")
                .font(.title.weight(.semibold))
            Text("Notes that record, transcribe, and think alongside you.")
                .foregroundStyle(.secondary)
            CodexSetupCard(state: setup.state)
                .padding(.top, Design.rowGap)
            createButton
                .padding(.top, Design.rowGap)
                .animation(Design.Anim.standard, value: setup.state)
        }
        .frame(maxWidth: 420)
        .padding(Design.paneInset)
        .task { await setup.poll() }
    }

    /// The pane's one prominent action swaps with setup state: while the
    /// card still needs the user, its button carries the weight and this
    /// one steps back.
    @ViewBuilder
    private var createButton: some View {
        if setup.state == .connected {
            Button("Create Your First Note", action: createNote)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else {
            Button("Create Your First Note", action: createNote)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }
}

/// The live connection card, centered like the rest of the pane. While
/// setup is unfinished it wears the StatusBanner tint (the one warning
/// treatment, applied to the card shape) and carries the pane's prominent
/// action; connected, it collapses to a neutral one-line confirmation.
private struct CodexSetupCard: View {
    let state: CodexSetupState

    var body: some View {
        Group {
            if state == .connected {
                HStack(spacing: Design.iconGap) {
                    StatusDot(color: .statusOK)
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                .padding(Design.paneInset)
                .frame(maxWidth: .infinity)
                .card()
            } else {
                VStack(spacing: Design.rowGap) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusWarning)
                    Text(message)
                        .multilineTextAlignment(.center)
                    actionButton
                }
                .padding(Design.paneInset)
                .frame(maxWidth: .infinity)
                .card(fill: Color.statusWarning.opacity(0.1), stroke: Color.statusWarning.opacity(0.35))
            }
        }
        .animation(Design.Anim.standard, value: state)
    }

    private var message: String {
        switch state {
        case .notInstalled:
            "ChatGPT app not found. Simbi uses it to transcribe and chat."
        case .signedOut:
            "ChatGPT is installed but signed out. Sign in there and Simbi connects automatically."
        case .connected:
            "Codex connected. Transcription and chat ready."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notInstalled:
            Button("Get ChatGPT") {
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com/download")!)
            }
            .buttonStyle(.borderedProminent)
        case .signedOut:
            Button("Open ChatGPT") {
                NSWorkspace.shared.open(URL(filePath: "/Applications/ChatGPT.app"))
            }
            .buttonStyle(.borderedProminent)
        case .connected:
            EmptyView()
        }
    }
}
