import Foundation
import SimbiKit

/// Generates a note's AI notes (AI Notes spec §3): one fresh thread per
/// generation (cwd = note folder, read-only sandbox), one turn whose prompt
/// inlines SUMMARY.md instructions, note.md, transcript.vtt, and any
/// current summary.md; the deliverable is the agent's final message text.
/// The caller writes summary.md — the thread writes nothing.
public actor NoteSummarizer {
    public enum SummarizerError: Error {
        case noOutput
        case timeout
        case malformedResponse
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
    /// the turn completes is the document.
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

    /// Pure prompt assembly, split out for testability (spec §3).
    nonisolated static func prompt(
        instructions: String, myNotes: String, transcript: String, currentSummary: String?
    ) -> String {
        let notes = myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = [
            instructions,
            "## The user's own notes (note.md)\n\n"
                + (notes.isEmpty ? "(the user has not written any notes)" : notes),
            "## The transcript (transcript.vtt)\n\n" + transcript,
        ]
        if let currentSummary {
            sections.append(
                "## Current AI notes (summary.md): update these in place\n\n" + currentSummary)
        }
        return sections.joined(separator: "\n\n")
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

    /// Models sometimes wrap the whole reply in a code fence despite the
    /// instructions; strip exactly one wrapping fence (any info string).
    nonisolated static func normalize(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2,
            lines.first?.hasPrefix("```") == true,
            lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else { return trimmed }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs one generation end-to-end and returns the normalized document.
    /// The thread is archived on the way out, success or failure.
    public func generate(
        myNotes: String, transcript: String, currentSummary: String?
    ) async throws -> String {
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
                "sandbox": "read-only",
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

        let prompt = Self.prompt(
            instructions: instructionsProvider(), myNotes: myNotes,
            transcript: transcript, currentSummary: currentSummary)
        let input: [[String: any Sendable]] = [
            ["type": "text", "text": prompt, "text_elements": [String]()]
        ]
        var turnParams: [String: any Sendable] = [
            "threadId": threadId,
            "input": input,
            "approvalPolicy": "never",
            // Wire-shape contingency: `readOnly` follows the app-server
            // protocol's camelCase convention (references/codex-remote-tui/
            // README.md documents the method names), but no existing Simbi
            // worker exercises it. If hand-testing rejects `turn/start`,
            // fall back to the converter's proven shape with nothing
            // writable: ["type": "workspaceWrite", "writableRoots":
            // [String](), "networkAccess": false, "excludeTmpdirEnvVar":
            // false, "excludeSlashTmp": false]. Likewise, if generation
            // ends in `noOutput`, inspect one real `item/completed`
            // payload (temporary print in the notification handler) and
            // adjust `agentMessage(fromItemCompleted:)`.
            "sandboxPolicy": ["type": "readOnly"] as [String: any Sendable],
        ]
        if let model {
            turnParams["model"] = model
        }
        _ = try await client.request(method: "turn/start", params: turnParams)
        try await awaitTurnCompletion(threadId: threadId)

        guard let text = messages[threadId] else { throw SummarizerError.noOutput }
        let document = Self.normalize(text)
        guard !document.isEmpty else { throw SummarizerError.noOutput }
        return document
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
