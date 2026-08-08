import Foundation
import SimbiKit

/// Runs the per-file converter jobs for one note (SPEC.md §5.3): each
/// imported file gets its own Codex thread (cwd = note folder,
/// workspace-write sandbox) with one turn that converts `files/<name>` to
/// `context/<name>.md`; the thread is archived when the job ends.
public actor FileConverter {
    public enum ConversionError: Error {
        case outputMissing
        case timeout
    }

    private let noteFolderURL: URL
    private let client: AppServerClient
    /// Model override for conversion turns (SPEC.md §5.5); nil = default.
    private let model: String?
    /// Generous ceiling — odd formats can send the agent exploring.
    private let turnTimeout: Duration
    /// INGEST.md's template text, fetched per job so edits apply to the
    /// next conversion without an app restart. `{{ file }}` is the
    /// imported file's name.
    private let instructionsTemplate: @Sendable () -> String

    private var bound = false
    private var waiting: [String: CheckedContinuation<Void, any Error>] = [:]
    /// Converter threads with a job in flight — the shared client fans every
    /// notification out to us, so ignore other threads' turns (the fixer's).
    private var activeThreads: Set<String> = []
    /// Threads whose turn completed before the waiter was registered.
    private var completedTurns: Set<String> = []

    public init(
        noteFolderURL: URL, client: AppServerClient, model: String? = nil,
        turnTimeout: Duration = .seconds(900),
        instructionsTemplate: @escaping @Sendable () -> String = {
            AgentInstructions.ingest.defaultContents
        }
    ) {
        self.noteFolderURL = noteFolderURL
        self.client = client
        self.model = model
        self.turnTimeout = turnTimeout
        self.instructionsTemplate = instructionsTemplate
    }

    private func instructions(fileName: String) -> String {
        AgentInstructions.render(instructionsTemplate(), variables: ["file": fileName])
    }

    /// Converts one imported file end-to-end; returns when `context/` holds
    /// the result. `onThreadStarted` fires as soon as the thread id is known
    /// so the caller can persist it (SPEC.md §5.1: state.json records thread
    /// ids). The thread is archived on the way out, success or failure.
    public func convert(
        fileName: String, onThreadStarted: @Sendable (String) async -> Void = { _ in }
    ) async throws {
        if !bound {
            bound = true
            await client.addNotificationHandler { [weak self] method, paramsData in
                guard method == "turn/completed" else { return }
                let params =
                    (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any]
                guard let threadId = params?["threadId"] as? String else { return }
                Task { await self?.turnCompleted(threadId: threadId) }
            }
        }

        let resultData = try await client.request(
            method: "thread/start",
            params: [
                "cwd": noteFolderURL.path,
                "approvalPolicy": "never",
                "sandbox": "workspace-write",
            ])
        let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        guard let thread = result?["thread"] as? [String: Any],
            let threadId = thread["id"] as? String
        else { throw AppServerClient.ClientError.malformedResponse }
        activeThreads.insert(threadId)
        await onThreadStarted(threadId)

        defer {
            activeThreads.remove(threadId)
            completedTurns.remove(threadId)
            // Archived when the job ends (§5.3) — success or failure.
            Task { [client] in
                _ = try? await client.request(
                    method: "thread/archive", params: ["threadId": threadId])
            }
        }

        // Naming forces rollout persistence (M1 spike gotcha #2).
        _ = try await client.request(
            method: "thread/name/set",
            params: ["threadId": threadId, "name": "[simbi] convert: \(fileName)"])

        let input: [[String: any Sendable]] = [
            ["type": "text", "text": instructions(fileName: fileName), "text_elements": [String]()]
        ]
        let sandboxPolicy: [String: any Sendable] = [
            "type": "workspaceWrite",
            "writableRoots": [noteFolderURL.path],
            "networkAccess": false,
            "excludeTmpdirEnvVar": false,
            "excludeSlashTmp": false,
        ]
        var turnParams: [String: any Sendable] = [
            "threadId": threadId,
            "input": input,
            "approvalPolicy": "never",
            "sandboxPolicy": sandboxPolicy,
        ]
        if let model {
            turnParams["model"] = model
        }
        _ = try await client.request(method: "turn/start", params: turnParams)
        try await awaitTurnCompletion(threadId: threadId)

        let output = noteFolderURL.appending(path: "context/\(fileName).md")
        let size =
            (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw ConversionError.outputMissing }
    }

    private func awaitTurnCompletion(threadId: String) async throws {
        if completedTurns.remove(threadId) != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiting[threadId] = continuation
            Task {  // inherits actor isolation
                try? await Task.sleep(for: turnTimeout)
                waiting.removeValue(forKey: threadId)?.resume(
                    throwing: ConversionError.timeout)
            }
        }
    }

    private func turnCompleted(threadId: String) {
        guard activeThreads.contains(threadId) else { return }
        if let continuation = waiting.removeValue(forKey: threadId) {
            continuation.resume()
        } else {
            completedTurns.insert(threadId)
        }
    }
}
