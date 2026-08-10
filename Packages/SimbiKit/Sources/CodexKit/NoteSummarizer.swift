import Foundation
import SimbiKit

/// Generates a note's AI notes (AI Notes spec §3): one fresh thread per
/// generation (cwd = note folder, workspace-write sandbox), one turn whose
/// input is the SUMMARY.md instructions. The thread reads note.md,
/// transcript.vtt, context/*.md, and any current summary.md from its own
/// cwd and writes summary.md itself by design (user decision 2026-08-10),
/// converter-style; its final message is only a DONE/FAILED status reply.
public actor NoteSummarizer {
    public enum SummarizerError: Error {
        case noOutput
        case timeout
        case malformedResponse
        /// The thread replied "FAILED: <reason>"; carries the trimmed
        /// first line of that reply.
        case reportedFailure(String)
    }

    private let noteFolderURL: URL
    private let client: AppServerClient
    private let model: String?
    private let turnTimeout: Duration
    /// Fetched per generation so SUMMARY.md edits apply to the next run
    /// without an app restart (same contract as the converter's INGEST.md).
    private let instructionsProvider: @Sendable () -> String

    private var bound = false
    private var waiting: [String: CheckedContinuation<Void, any Error>] = [:]
    private var activeThreads: Set<String> = []
    private var completedTurns: Set<String> = []
    /// Last agentMessage text seen per active thread; the final one when
    /// the turn completes is the DONE/FAILED status reply — never file
    /// content (the thread writes summary.md itself).
    private var messages: [String: String] = [:]

    public init(
        noteFolderURL: URL, client: AppServerClient, model: String? = nil,
        turnTimeout: Duration = .seconds(600),
        instructionsProvider: @escaping @Sendable () -> String = {
            AgentInstructions.summary.contents(homeRootURL: SimbiHome().rootURL)
        }
    ) {
        self.noteFolderURL = noteFolderURL
        self.client = client
        self.model = model
        self.turnTimeout = turnTimeout
        self.instructionsProvider = instructionsProvider
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

    /// Runs one generation end-to-end; the thread has written summary.md
    /// when this returns. The thread is archived on the way out, success
    /// or failure.
    public func generate() async throws {
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
        else { throw SummarizerError.malformedResponse }
        activeThreads.insert(threadId)

        defer {
            activeThreads.remove(threadId)
            completedTurns.remove(threadId)
            messages.removeValue(forKey: threadId)
            Task { [client] in
                _ = try? await client.request(
                    method: "thread/archive", params: ["threadId": threadId])
            }
        }

        // Naming forces rollout persistence (M1 spike gotcha #2).
        _ = try await client.request(
            method: "thread/name/set",
            params: [
                "threadId": threadId,
                "name": "[simbi] summary: \(noteFolderURL.lastPathComponent)",
            ])

        let input: [[String: any Sendable]] = [
            ["type": "text", "text": instructionsProvider(), "text_elements": [String]()]
        ]
        // Same sandbox shape as the converter: the thread writes summary.md
        // in the note folder itself by design (user decision 2026-08-10).
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

        if let text = messages[threadId], let reason = Self.reportedFailure(in: text) {
            throw SummarizerError.reportedFailure(reason)
        }
        let output = noteFolderURL.appending(path: "summary.md")
        let size =
            (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw SummarizerError.noOutput }
    }

    private func record(text: String, threadId: String) {
        guard activeThreads.contains(threadId) else { return }
        messages[threadId] = text
    }

    private func awaitTurnCompletion(threadId: String) async throws {
        if completedTurns.remove(threadId) != nil { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            waiting[threadId] = continuation
            Task {  // inherits actor isolation
                try? await Task.sleep(for: turnTimeout)
                waiting.removeValue(forKey: threadId)?.resume(
                    throwing: SummarizerError.timeout)
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
