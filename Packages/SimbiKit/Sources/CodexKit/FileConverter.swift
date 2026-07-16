import Foundation

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
    /// Generous ceiling — odd formats can send the agent exploring.
    private let turnTimeout: Duration

    private var bound = false
    private var waiting: [String: CheckedContinuation<Void, any Error>] = [:]
    /// Converter threads with a job in flight — the shared client fans every
    /// notification out to us, so ignore other threads' turns (the fixer's).
    private var activeThreads: Set<String> = []
    /// Threads whose turn completed before the waiter was registered.
    private var completedTurns: Set<String> = []

    public init(
        noteFolderURL: URL, client: AppServerClient, turnTimeout: Duration = .seconds(900)
    ) {
        self.noteFolderURL = noteFolderURL
        self.client = client
        self.turnTimeout = turnTimeout
    }

    private func instructions(fileName: String) -> String {
        """
        Convert files/\(fileName) to a markdown mirror at context/\(fileName).md \
        (create the context/ directory if needed).

        Known starting points for reading the format: textutil, mdls, sips, \
        python3. If none of them fit, find your own way to read the format.

        Hard requirement: NO information loss — prefer verbose fidelity over \
        pretty summarization. Tables stay tables, numbers stay exact, all text \
        content is carried over. Describe images/figures in place.

        Never modify files/\(fileName) or anything outside context/. Reply with \
        one line: DONE, or FAILED: <reason>.
        """
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
        _ = try await client.request(
            method: "turn/start",
            params: [
                "threadId": threadId,
                "input": input,
                "approvalPolicy": "never",
                "sandboxPolicy": sandboxPolicy,
            ])
        try await awaitTurnCompletion(threadId: threadId)

        let output = noteFolderURL.appending(path: "context/\(fileName).md")
        let size =
            (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw ConversionError.outputMissing }
    }

    private func awaitTurnCompletion(threadId: String) async throws {
        if completedTurns.remove(threadId) != nil { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
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
