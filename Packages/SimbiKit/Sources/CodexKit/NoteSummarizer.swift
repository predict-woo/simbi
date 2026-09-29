import Foundation
import SimbiKit

/// Generates a note's AI notes (AI Notes spec §3): one fresh thread in the
/// shared Simbi Codex project per generation, with its writable sandbox scoped
/// to the note folder. The turn reads note.md,
/// transcript.vtt, context/*.md, and any current summary.md from its task
/// directory and writes summary.md itself by design (user decision 2026-08-10),
/// converter-style; its final message is only a DONE/FAILED status reply.
public actor NoteSummarizer {
    private let noteFolderURL: URL
    private let runner: CodexWorkerTurnRunner
    /// Fetched per generation so SUMMARY.md edits apply to the next run
    /// without an app restart (same contract as the converter's INGEST.md).
    private let instructionsProvider: @Sendable () -> String

    public init(
        noteFolderURL: URL, client: AppServerClient, model: String? = nil,
        effort: String? = nil,
        projectRootURL: URL = SimbiHome().rootURL,
        turnTimeout: Duration = .seconds(600),
        instructionsProvider: @escaping @Sendable () -> String = {
            AgentInstructions.summary.contents(homeRootURL: SimbiHome().rootURL)
        }
    ) {
        self.noteFolderURL = noteFolderURL
        self.instructionsProvider = instructionsProvider
        // Same sandbox shape as the converter: the thread writes summary.md
        // in the note folder itself by design (user decision 2026-08-10).
        self.runner = CodexWorkerTurnRunner(
            client: client,
            spec: .init(
                project: SimbiCodexProject(rootURL: projectRootURL),
                noteFolderURL: noteFolderURL, taskDirectoryURL: noteFolderURL,
                sandbox: "workspace-write", writableRoot: noteFolderURL,
                model: model, effort: effort, turnTimeout: turnTimeout))
    }

    /// Runs one generation end-to-end; the thread has written summary.md
    /// when this returns. The thread is archived on the way out, success
    /// or failure.
    public func generate() async throws {
        let message = try await runner.run(
            instructions: instructionsProvider(),
            role: "AI Notes")

        if let message, let reason = CodexWorkerTurnRunner.reportedFailure(in: message) {
            throw CodexWorkerError.reportedFailure(reason)
        }
        let output = NoteLayout.summaryURL(noteFolder: noteFolderURL)
        guard WorkerOutput.exists(at: output) else { throw CodexWorkerError.noOutput }
    }
}
