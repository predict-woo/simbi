import Foundation
import SimbiKit

/// A pending approval surfaced to the chat UI. `id` is a local token tying
/// the UI's decision back to the suspended server request.
public struct ChatApprovalRequest: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case commandExecution(command: String, cwd: String?, reason: String?)
        case fileChange(files: [String], reason: String?)
    }

    public let id: UUID
    public let itemId: String
    public let kind: Kind
}

public enum ChatSessionEvent: Sendable {
    case event(ChatEvent)
    case approvalRequested(ChatApprovalRequest)
    case approvalSettled(UUID)
}

/// The note's chat thread over the shared app-server (SPEC.md §5.4):
/// resume-or-create with a persisted thread id, workspace-write turns with
/// on-request approvals, and a single event stream for the UI.
public actor ChatSession {
    private let noteFolderURL: URL
    private let homeRootURL: URL
    private let client: AppServerClient
    private let model: String?

    private var threadId: String?
    private var bound = false
    private var continuation: AsyncStream<ChatSessionEvent>.Continuation?
    private var pendingApprovals: [UUID: CheckedContinuation<String, Never>] = [:]

    public init(
        noteFolderURL: URL, homeRootURL: URL, client: AppServerClient, model: String?
    ) {
        self.noteFolderURL = noteFolderURL
        self.homeRootURL = homeRootURL
        self.client = client
        self.model = model
    }

    /// Single-consumer stream; the UI model is the only listener.
    public func events() -> AsyncStream<ChatSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatSessionEvent.self)
        self.continuation = continuation
        return stream
    }

    /// Resume the persisted thread (fresh-start fallback if it's gone) and
    /// return its history for the transcript.
    public func ensureThread() async throws -> [ChatItem] {
        try await bindHandlers()
        if let saved = try? NoteRecordingState.load(noteFolder: noteFolderURL).chatThreadId {
            do {
                _ = try await client.request(
                    method: "thread/resume", params: ["threadId": saved])
                threadId = saved
                let read = try await client.request(
                    method: "thread/read",
                    params: ["threadId": saved, "includeTurns": true])
                return Self.history(fromThreadReadResult: read)
            } catch {
                // Deleted/corrupt thread: fall through to a fresh one.
            }
        }
        try await startFreshThread()
        return []
    }

    public func send(_ text: String) async throws {
        guard let threadId else { return }
        let input: [[String: any Sendable]] = [
            ["type": "text", "text": text, "text_elements": [String]()]
        ]
        // Workspace-write rooted at the thread's cwd (the home root), with
        // approvals surfaced to the user — unlike the fixer's silent
        // never-ask worktree policy.
        let sandboxPolicy: [String: any Sendable] = [
            "type": "workspaceWrite",
            "networkAccess": false,
            "excludeTmpdirEnvVar": false,
            "excludeSlashTmp": false
        ]
        var params: [String: any Sendable] = [
            "threadId": threadId,
            "input": input,
            "approvalPolicy": "on-request",
            "sandboxPolicy": sandboxPolicy
        ]
        if let model {
            params["model"] = model
        }
        _ = try await client.request(method: "turn/start", params: params)
    }

    public func interrupt(turnId: String?) async {
        guard let threadId, let turnId else { return }
        _ = try? await client.request(
            method: "turn/interrupt", params: ["threadId": threadId, "turnId": turnId])
    }

    /// Archives the current thread and creates a fresh one.
    public func newChat() async throws {
        if let threadId {
            _ = try? await client.request(
                method: "thread/archive", params: ["threadId": threadId])
        }
        threadId = nil
        try? NoteRecordingState.update(noteFolder: noteFolderURL) { $0.chatThreadId = nil }
        try await startFreshThread()
    }

    /// decision: "accept" | "acceptForSession" | "decline" | "cancel"
    public func resolveApproval(id: UUID, decision: String) {
        guard let waiting = pendingApprovals.removeValue(forKey: id) else { return }
        waiting.resume(returning: decision)
        continuation?.yield(.approvalSettled(id))
    }

    // MARK: - wiring

    private func bindHandlers() async throws {
        guard !bound else { return }
        bound = true
        await client.addNotificationHandler { [weak self] method, paramsData in
            guard
                let params = (try? JSONSerialization.jsonObject(with: paramsData))
                    as? [String: Any],
                let parsed = ChatEventParser.parse(method: method, params: params)
            else { return }
            Task { await self?.forward(threadId: parsed.threadId, event: parsed.event) }
        }
        await client.addServerRequestHandler { [weak self] method, paramsData in
            guard let self else { return .notMine }
            return await self.handleServerRequest(method: method, paramsData: paramsData)
        }
    }

    private func forward(threadId: String, event: ChatEvent) {
        guard threadId == self.threadId else { return }
        if case .turnCompleted = event {
            // A turn that ends with approvals still pending (interrupt,
            // failure) must not leave the server request hanging.
            for (id, waiting) in pendingApprovals {
                waiting.resume(returning: "cancel")
                continuation?.yield(.approvalSettled(id))
            }
            pendingApprovals.removeAll()
        }
        continuation?.yield(.event(event))
    }

    private func handleServerRequest(
        method: String, paramsData: Data
    ) async -> AppServerClient.ServerRequestReply {
        guard
            method == "item/commandExecution/requestApproval"
                || method == "item/fileChange/requestApproval",
            let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any],
            params["threadId"] as? String == threadId,
            let itemId = params["itemId"] as? String
        else { return .notMine }

        let kind: ChatApprovalRequest.Kind =
            method == "item/commandExecution/requestApproval"
            ? .commandExecution(
                command: params["command"] as? String ?? "",
                cwd: params["cwd"] as? String,
                reason: params["reason"] as? String)
            : .fileChange(
                // The wire request carries no file list; the matching
                // fileChange item row (same itemId) shows the files.
                files: [], reason: params["reason"] as? String)
        let request = ChatApprovalRequest(id: UUID(), itemId: itemId, kind: kind)
        let decision = await withCheckedContinuation { waiting in
            pendingApprovals[request.id] = waiting
            continuation?.yield(.approvalRequested(request))
        }
        return .result(["decision": decision])
    }

    private func startFreshThread() async throws {
        let resultData = try await client.request(
            method: "thread/start", params: ["cwd": homeRootURL.path])
        let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        guard let thread = result?["thread"] as? [String: Any],
            let id = thread["id"] as? String
        else { throw AppServerClient.ClientError.malformedResponse }
        threadId = id
        // Naming forces rollout persistence (M1 spike gotcha #2) and is the
        // user's handle in the ChatGPT app's history.
        _ = try await client.request(
            method: "thread/name/set",
            params: ["threadId": id, "name": "\(noteFolderURL.lastPathComponent) — chat"])
        try? NoteRecordingState.update(noteFolder: noteFolderURL) { $0.chatThreadId = id }

        let relativePath = CodexChat.notePath(
            noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        let prompt = """
            The user wants to discuss the note at `\(relativePath)`. Read its \
            `note.md`, `transcript.vtt`, and `context/*.md` (whatever exists), \
            then answer their next message.
            """
        var params: [String: any Sendable] = [
            "threadId": id,
            "input": [["type": "text", "text": prompt, "text_elements": [String]()]]
                as [[String: any Sendable]]
        ]
        if let model {
            params["model"] = model
        }
        _ = try await client.request(method: "turn/start", params: params)
    }

    /// `thread/read` → ordered ChatItems. Defensive: absent turns/items are
    /// an empty history, never an error.
    public static func history(fromThreadReadResult data: Data) -> [ChatItem] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let thread = object["thread"] as? [String: Any],
            let turns = thread["turns"] as? [[String: Any]]
        else { return [] }
        return turns.flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap(ChatEventParser.item(from:))
        }
    }
}
