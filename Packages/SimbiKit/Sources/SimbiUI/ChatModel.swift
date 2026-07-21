import CodexKit
import Foundation
import Observation
import SimbiKit

/// UI model for one note's chat window. Shared per note (like FilesModel)
/// so the conversation survives window close/reopen within a session.
@MainActor
@Observable
final class ChatModel {
    enum Phase: Equatable {
        case connecting
        case ready
        case unavailable(String)
    }

    private static var models: [URL: ChatModel] = [:]

    static func shared(noteFolderURL: URL) -> ChatModel {
        if let existing = models[noteFolderURL] { return existing }
        let model = ChatModel(noteFolderURL: noteFolderURL)
        models[noteFolderURL] = model
        return model
    }

    private(set) var transcript = ChatTranscript()
    private(set) var pendingApprovals: [ChatApprovalRequest] = []
    private(set) var phase: Phase = .connecting
    var composerText = ""

    let noteFolderURL: URL
    private let session: ChatSession
    private var started = false

    private init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let settings =
            (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
        self.session = ChatSession(
            noteFolderURL: noteFolderURL,
            homeRootURL: SimbiHome().rootURL,
            client: CodexServices.appServer,
            model: settings.chatModel)
    }

    /// Idempotent; called from the window's .task.
    func start() {
        guard !started else { return }
        started = true
        guard CodexInstallation.standard.isBinaryInstalled else {
            phase = .unavailable(
                "ChatGPT app not found — chat needs the bundled codex app-server.")
            return
        }
        Task {
            let events = await session.events()
            Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
            do {
                let history = try await session.ensureThread()
                transcript = ChatTranscript(history: history)
                phase = .ready
            } catch {
                phase = .unavailable("Could not reach the Codex app-server.")
            }
        }
    }

    func sendCurrentMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .ready, !transcript.turnActive else { return }
        composerText = ""
        transcript.appendLocalUser(text: text)
        Task {
            do {
                try await session.send(text)
            } catch {
                transcript.appendBanner("Sending failed — the app-server may be restarting.")
            }
        }
    }

    func interrupt() {
        let turnId = transcript.activeTurnId
        Task { await session.interrupt(turnId: turnId) }
    }

    func newChat() {
        transcript = ChatTranscript()
        pendingApprovals = []
        phase = .connecting
        Task {
            do {
                try await session.newChat()
                phase = .ready
            } catch {
                phase = .unavailable("Could not start a new chat thread.")
            }
        }
    }

    func respond(to approval: ChatApprovalRequest, decision: String) {
        pendingApprovals.removeAll { $0.id == approval.id }
        Task { await session.resolveApproval(id: approval.id, decision: decision) }
    }

    private func handle(_ event: ChatSessionEvent) {
        switch event {
        case .event(let chatEvent):
            transcript.apply(chatEvent)
        case .approvalRequested(let request):
            pendingApprovals.append(request)
        case .approvalSettled(let id):
            pendingApprovals.removeAll { $0.id == id }
        }
    }
}
