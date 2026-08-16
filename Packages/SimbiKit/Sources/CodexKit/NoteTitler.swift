import Foundation
import SimbiKit

/// Names a note whose title is still the default: one fresh read-only
/// thread per attempt (cwd = note folder, `sandbox: read-only`), one turn
/// whose input is the TITLE.md instructions. Unlike the summarizer the
/// thread writes nothing — its final agent message IS the result, which
/// `sanitizedTitle` turns into a folder-safe name.
public actor NoteTitler {
    public enum TitlerError: Error {
        case noOutput
        case timeout
        case malformedResponse
        /// The thread replied "FAILED: <reason>"; carries the trimmed
        /// first line of that reply.
        case reportedFailure(String)
    }

    private static let maxTitleLength = 64

    private let noteFolderURL: URL
    private let client: AppServerClient
    private let model: String?
    /// Reasoning-effort override; nil = the model's own default.
    private let effort: String?
    private let turnTimeout: Duration
    /// Fetched per attempt so TITLE.md edits apply to the next run
    /// without an app restart (same contract as the summarizer).
    private let instructionsProvider: @Sendable () -> String

    private var bound = false
    private var waiting: [String: CheckedContinuation<Void, any Error>] = [:]
    private var activeThreads: Set<String> = []
    private var completedTurns: Set<String> = []
    /// Last agentMessage text seen per active thread; the final one when
    /// the turn completes is the title reply itself.
    private var messages: [String: String] = [:]

    public init(
        noteFolderURL: URL, client: AppServerClient, model: String? = nil,
        effort: String? = nil,
        turnTimeout: Duration = .seconds(180),
        instructionsProvider: @escaping @Sendable () -> String = {
            AgentInstructions.title.contents(homeRootURL: SimbiHome().rootURL)
        }
    ) {
        self.noteFolderURL = noteFolderURL
        self.client = client
        self.model = model
        self.effort = effort
        self.turnTimeout = turnTimeout
        self.instructionsProvider = instructionsProvider
    }

    /// The reply reduced to a folder-safe title: first line, wrapping
    /// quotes/backticks/fences stripped, `/` and `:` neutralized, leading
    /// dots dropped (hidden folders), capped at a word boundary. Nil when
    /// nothing usable remains — the caller treats that as no title.
    nonisolated public static func sanitizedTitle(from message: String) -> String? {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("```") {
            text = String(text.dropFirst(3))
            if let fenceEnd = text.range(of: "```") {
                text = String(text[..<fenceEnd.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = String(text.prefix(while: { !$0.isNewline }))

        let wrappers: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`"),
        ]
        var stripped = true
        while stripped {
            stripped = false
            text = text.trimmingCharacters(in: .whitespaces)
            for (open, close) in wrappers
            where text.count >= 2 && text.first == open && text.last == close {
                text = String(text.dropFirst().dropLast())
                stripped = true
            }
        }

        text = text.replacingOccurrences(of: "/", with: "-")
        text = text.replacingOccurrences(of: ":", with: " ")
        text = text.split(separator: " ").joined(separator: " ")
        while text.hasPrefix(".") {
            text = String(text.dropFirst())
        }

        if text.count > maxTitleLength {
            let cut = text.prefix(maxTitleLength)
            text = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }

        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        return text
    }

    /// Runs one attempt end-to-end and returns the sanitized title. The
    /// thread is archived on the way out, success or failure.
    public func generateTitle() async throws -> String {
        if !bound {
            bound = true
            await client.addNotificationHandler { [weak self] method, paramsData in
                switch method {
                case "item/completed":
                    guard let parsed = NoteSummarizer.agentMessage(fromItemCompleted: paramsData)
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

        // Read-only: the titler never touches disk (verified thread/start
        // shape in references/codex-remote-tui). The turn inherits the
        // thread's sandbox.
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
        else { throw TitlerError.malformedResponse }
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
                "name": "[simbi] title: \(noteFolderURL.lastPathComponent)",
            ])

        let input: [[String: any Sendable]] = [
            ["type": "text", "text": instructionsProvider(), "text_elements": [String]()]
        ]
        var turnParams: [String: any Sendable] = [
            "threadId": threadId,
            "input": input,
            "approvalPolicy": "never",
        ]
        TurnOverrides.apply(model: model, effort: effort, to: &turnParams)
        _ = try await client.request(method: "turn/start", params: turnParams)
        try await awaitTurnCompletion(threadId: threadId)

        guard let text = messages[threadId] else { throw TitlerError.noOutput }
        if let reason = NoteSummarizer.reportedFailure(in: text) {
            throw TitlerError.reportedFailure(reason)
        }
        guard let title = Self.sanitizedTitle(from: text) else { throw TitlerError.noOutput }
        return title
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
                    throwing: TitlerError.timeout)
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
