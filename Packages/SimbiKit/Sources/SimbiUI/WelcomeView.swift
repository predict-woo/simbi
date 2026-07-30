import AppKit
import CodexKit
import SimbiKit
import SwiftUI

/// First-run welcome pane, shown in the detail area whenever the library
/// has zero notes (spec: 2026-07-23-first-run-onboarding-design.md).
/// No stored state — it disappears the moment a note exists and returns
/// only if the library is ever empty again.
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
            Button("Create Your First Note", action: createNote)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, Design.rowGap)
            Text("then press Record")
                .font(.meta)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420)
        .padding(Design.paneInset)
        .task { await setup.poll() }
    }
}

/// The live three-step connection card: not installed → signed out →
/// connected, advancing on its own as the model polls.
private struct CodexSetupCard: View {
    let state: CodexSetupState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: state == .connected ? .statusOK : .statusWarning)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: Design.innerGap) {
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionButton
            }
        }
        .padding(Design.paneInset)
        .card()
        .animation(.default, value: state)
    }

    private var message: String {
        switch state {
        case .notInstalled:
            "ChatGPT app not found — Simbi uses it to transcribe and chat."
        case .signedOut:
            "ChatGPT is installed but signed out. Sign in there and Simbi connects automatically."
        case .connected:
            "Codex connected — transcription and chat ready."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notInstalled:
            Button("Get ChatGPT") {
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com/download")!)
            }
            .buttonStyle(.link)
            .font(.metaSemibold)
        case .signedOut:
            Button("Open ChatGPT") {
                NSWorkspace.shared.open(URL(filePath: "/Applications/ChatGPT.app"))
            }
            .buttonStyle(.link)
            .font(.metaSemibold)
        case .connected:
            EmptyView()
        }
    }
}
