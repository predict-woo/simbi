import CodexKit
import GhosttyTerminal
import SimbiKit
import SwiftUI

/// One ghostty app shared by every chat terminal. The command is one
/// constant string (`TerminalChatLaunch.commandLine`); everything per-note
/// travels in each surface's env vars, so surfaces can share the controller.
@MainActor
enum TerminalChatServices {
    static let controller = TerminalController(
        configSource: .none,
        terminalConfiguration: TerminalConfiguration { builder in
            builder.withCustom("command", TerminalChatLaunch.commandLine)
        }
    )
}

/// The per-note chat window (SPEC.md §5.4), now an embedded terminal
/// running the packaged codex TUI in the note's folder. Codex owns the
/// conversational UI — composer, streaming, approvals, model switching —
/// and starts with a developer message describing the note (see
/// `TerminalChatLaunch`). The app shell declares the matching WindowGroup.
public struct ChatWindow: View {
    public static let windowId = "note-chat"

    private let noteFolderURL: URL
    private let noteName: String

    public init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        self.noteName = noteFolderURL.lastPathComponent
    }

    public var body: some View {
        Group {
            if CodexInstallation.standard.isBinaryInstalled {
                TerminalChatView(noteFolderURL: noteFolderURL)
            } else {
                StatusBanner(
                    message: "ChatGPT app not found — chat needs the bundled codex."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Chat — \(noteName)")
        .frame(minWidth: 480, idealWidth: 680, minHeight: 420, idealHeight: 640)
    }
}

/// Hosts one note's codex session. When the process ends (ctrl-D, /quit,
/// crash) the surface stays up with an overlay offering a fresh session.
struct TerminalChatView: View {
    let noteFolderURL: URL

    @State private var state: TerminalViewState?
    @State private var sessionEnded = false
    @FocusState private var terminalFocused: Bool

    var body: some View {
        ZStack {
            if let state {
                TerminalSurfaceView(context: state)
                    .terminalFocusOnAppear($terminalFocused)
            }
            if sessionEnded {
                sessionEndedOverlay
            }
        }
        .onAppear {
            if state == nil { startSession() }
        }
    }

    private var sessionEndedOverlay: some View {
        VStack(spacing: Design.rowGap) {
            Text("Codex session ended")
                .font(.headline)
            Button("Start New Session") {
                startSession()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.overlay))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.25))
    }

    private func startSession() {
        sessionEnded = false
        let launch = TerminalChatLaunch.forNote(
            noteFolderURL: noteFolderURL, homeRootURL: SimbiHome().rootURL)
        let next = TerminalViewState(controller: TerminalChatServices.controller)
        next.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: noteFolderURL.path,
            envVars: launch.envVars)
        next.onClose = { _ in
            Task { @MainActor in sessionEnded = true }
        }
        state = next
        terminalFocused = true
    }
}
