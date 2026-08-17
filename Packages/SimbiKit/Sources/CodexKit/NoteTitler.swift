import Foundation
import SimbiKit

/// Names a note whose title is still the default: one fresh read-only
/// thread per attempt (cwd = note folder, `sandbox: read-only`), one turn
/// whose input is the TITLE.md instructions. Unlike the summarizer the
/// thread writes nothing — its final agent message IS the result, which
/// `sanitizedTitle` turns into a folder-safe name.
public actor NoteTitler {
    private static let maxTitleLength = 64

    private let runner: CodexWorkerTurnRunner

    public init(
        noteFolderURL: URL, client: AppServerClient, model: String? = nil,
        effort: String? = nil,
        turnTimeout: Duration = .seconds(180),
        instructionsProvider: @escaping @Sendable () -> String = {
            AgentInstructions.title.contents(homeRootURL: SimbiHome().rootURL)
        }
    ) {
        self.instructionsProvider = instructionsProvider
        self.noteFolderURL = noteFolderURL
        // Read-only: the titler never touches disk (verified thread/start
        // shape in references/codex-remote-tui). The turn inherits the
        // thread's sandbox, so no writable root is passed.
        self.runner = CodexWorkerTurnRunner(
            client: client,
            spec: .init(
                cwd: noteFolderURL, sandbox: "read-only", writableRoot: nil,
                model: model, effort: effort, turnTimeout: turnTimeout))
    }

    private let noteFolderURL: URL
    /// Fetched per attempt so TITLE.md edits apply to the next run
    /// without an app restart (same contract as the summarizer).
    private let instructionsProvider: @Sendable () -> String

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
        let message = try await runner.run(
            instructions: instructionsProvider(),
            threadName: "[simbi] title: \(noteFolderURL.lastPathComponent)")

        guard let message else { throw CodexWorkerError.noOutput }
        if let reason = CodexWorkerTurnRunner.reportedFailure(in: message) {
            throw CodexWorkerError.reportedFailure(reason)
        }
        guard let title = Self.sanitizedTitle(from: message) else {
            throw CodexWorkerError.noOutput
        }
        return title
    }
}
