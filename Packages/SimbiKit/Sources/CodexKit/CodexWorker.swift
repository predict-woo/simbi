import Foundation
import SimbiKit

/// Failures shared by the one-shot Codex worker actors (file converter,
/// summarizer, titler). Public because callers (SimbiUI) pattern-match
/// `reportedFailure` for logging.
public enum CodexWorkerError: Error {
    case timeout
    case malformedResponse
    /// The turn ended without the output the worker's contract requires
    /// (no file written, no usable reply).
    case noOutput
    /// The thread replied "FAILED: <reason>"; carries the trimmed first
    /// line of that reply.
    case reportedFailure(String)
}

/// Wire shapes shared by every worker turn (verified in
/// Sources/simbi-appserver-spike/README.md).
enum CodexTurn {
    /// A single text input item for `turn/start`.
    static func textInput(_ text: String) -> [[String: any Sendable]] {
        [["type": "text", "text": text, "text_elements": [String]()]]
    }

    /// Workspace-write sandbox scoped to one root.
    static func workspaceWritePolicy(writableRoot: URL) -> [String: any Sendable] {
        [
            "type": "workspaceWrite",
            "writableRoots": [writableRoot.path],
            "networkAccess": false,
            "excludeTmpdirEnvVar": false,
            "excludeSlashTmp": false,
        ]
    }

    /// The `turn/start` params every Simbi turn shares: never-approve, a
    /// text input, an optional workspace-write scope, and the caller's
    /// model/effort overrides. Used by the fixer and the one-shot workers.
    static func startParams(
        threadId: String, text: String, writableRoot: URL?, model: String?, effort: String?
    ) -> [String: any Sendable] {
        var params: [String: any Sendable] = [
            "threadId": threadId,
            "input": textInput(text),
            "approvalPolicy": "never",
        ]
        if let writableRoot {
            params["sandboxPolicy"] = workspaceWritePolicy(writableRoot: writableRoot)
        }
        TurnOverrides.apply(model: model, effort: effort, to: &params)
        return params
    }

    /// Parses a `thread/start` result into the new thread's id.
    static func threadId(fromStartResult resultData: Data) throws -> String {
        let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        guard let thread = result?["thread"] as? [String: Any],
            let id = thread["id"] as? String
        else { throw CodexWorkerError.malformedResponse }
        return id
    }

    /// `thread/start` + `thread/name/set` in one step — naming forces
    /// rollout persistence (M1 spike gotcha #2), so no Simbi thread ever
    /// starts unnamed.
    static func startThread(
        client: AppServerClient, cwd: URL, sandbox: String, name: String
    ) async throws -> String {
        let resultData = try await client.request(
            method: "thread/start",
            params: ["cwd": cwd.path, "approvalPolicy": "never", "sandbox": sandbox])
        let id = try threadId(fromStartResult: resultData)
        _ = try await client.request(
            method: "thread/name/set", params: ["threadId": id, "name": name])
        return id
    }
}

/// The worker contract's output check — the promised file exists and is
/// non-empty. Shared by the converter, the summarizer, and the UI's
/// grading of externally-driven converter turns.
public enum WorkerOutput {
    public static func exists(at url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) > 0
    }
}

/// The lifecycle shared by the one-shot worker actors: start one thread,
/// name it (naming forces rollout persistence — M1 spike gotcha #2), run
/// one turn, await its completion, collect the final agent message, and
/// archive the thread on the way out. Each worker keeps only its own
/// inputs (instructions, sandbox shape) and its own reading of the result.
///
/// Runs may overlap (the converter dispatches one per imported file); all
/// bookkeeping is per-thread.
actor CodexWorkerTurnRunner {
    struct Spec: Sendable {
        var cwd: URL
        /// `thread/start` sandbox ("workspace-write" / "read-only").
        var sandbox: String
        /// Turn sandbox scope; nil inherits the thread's sandbox (titler).
        var writableRoot: URL?
        var model: String?
        var effort: String?
        var turnTimeout: Duration
        /// Consulted when the run ends: false leaves the thread unarchived
        /// (a viewer window holds it open — its close handler archives
        /// instead; live-view spec §6).
        var shouldArchiveOnEnd: @Sendable (String) async -> Bool = { _ in true }
    }

    private let client: AppServerClient
    private let spec: Spec

    private var bound = false
    private var waiting: [String: CheckedContinuation<Void, any Error>] = [:]
    /// Threads with a run in flight — the shared client fans every
    /// notification out to us, so other threads' turns (the fixer's) are
    /// ignored.
    private var activeThreads: Set<String> = []
    /// Threads whose turn completed before the waiter was registered.
    private var completedTurns: Set<String> = []
    /// Last agentMessage text seen per active thread; the final one when
    /// the turn completes is the worker's status reply.
    private var messages: [String: String] = [:]

    init(client: AppServerClient, spec: Spec) {
        self.client = client
        self.spec = spec
    }

    /// `item/completed` → (threadId, text) when the item is the agent's
    /// message; nil for every other item type or shape.
    nonisolated static func agentMessage(
        fromItemCompleted paramsData: Data
    ) -> (threadId: String, text: String)? {
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any]
        guard let threadId = params?["threadId"] as? String,
            let item = params?["item"] as? [String: Any],
            item["type"] as? String == "agentMessage",
            let text = item["text"] as? String
        else { return nil }
        return (threadId, text)
    }

    /// The trimmed first line of the reply when it starts with "FAILED"
    /// (case-insensitive) — the instruction contract's failure shape —
    /// nil otherwise.
    nonisolated static func reportedFailure(in message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("failed") else { return nil }
        return String(trimmed.prefix(while: { !$0.isNewline }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Runs one thread+turn end-to-end and returns the final agent message
    /// (nil when the turn produced none). `onThreadStarted` fires as soon
    /// as the thread id is known so the caller can persist it (SPEC.md
    /// §5.1: state.json records thread ids).
    func run(
        instructions: String,
        threadName: String,
        onThreadStarted: @Sendable (String) async -> Void = { _ in }
    ) async throws -> String? {
        if !bound {
            bound = true
            await client.addNotificationHandler { [weak self] method, paramsData in
                switch method {
                case "item/completed":
                    guard let parsed = Self.agentMessage(fromItemCompleted: paramsData)
                    else { return }
                    Task { await self?.record(text: parsed.text, threadId: parsed.threadId) }
                case "turn/completed":
                    let params =
                        (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any]
                    guard let threadId = params?["threadId"] as? String else { return }
                    Task { await self?.turnCompleted(threadId: threadId) }
                default:
                    break
                }
            }
        }

        let threadId = try await CodexTurn.startThread(
            client: client, cwd: spec.cwd, sandbox: spec.sandbox, name: threadName)
        activeThreads.insert(threadId)
        await onThreadStarted(threadId)

        defer {
            activeThreads.remove(threadId)
            completedTurns.remove(threadId)
            messages.removeValue(forKey: threadId)
            // Archived when the run ends — success or failure — unless a
            // viewer window holds the thread open.
            Task { [client, shouldArchive = spec.shouldArchiveOnEnd] in
                guard await shouldArchive(threadId) else { return }
                do {
                    _ = try await client.request(
                        method: "thread/archive", params: ["threadId": threadId])
                } catch {
                    Log.codex.warning("archiving worker thread \(threadId) failed: \(error)")
                }
            }
        }

        _ = try await client.request(
            method: "turn/start",
            params: CodexTurn.startParams(
                threadId: threadId, text: instructions, writableRoot: spec.writableRoot,
                model: spec.model, effort: spec.effort))
        try await awaitTurnCompletion(threadId: threadId)
        return messages[threadId]
    }

    private func record(text: String, threadId: String) {
        guard activeThreads.contains(threadId) else { return }
        messages[threadId] = text
    }

    private func awaitTurnCompletion(threadId: String) async throws {
        if completedTurns.remove(threadId) != nil { return }
        // Cancelled once the turn completes, so a finished run leaves no
        // timer sleeping out the full timeout.
        let timeout = Task { [turnTimeout = spec.turnTimeout] in
            try? await Task.sleep(for: turnTimeout)
            guard !Task.isCancelled else { return }
            timedOut(threadId: threadId)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            waiting[threadId] = continuation
        }
    }

    private func timedOut(threadId: String) {
        waiting.removeValue(forKey: threadId)?.resume(throwing: CodexWorkerError.timeout)
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
