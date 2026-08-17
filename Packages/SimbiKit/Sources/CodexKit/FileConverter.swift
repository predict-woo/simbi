import Foundation
import SimbiKit

/// Runs the per-file converter jobs for one note (SPEC.md §5.3): each
/// imported file gets its own Codex thread (cwd = note folder,
/// workspace-write sandbox) with one turn that converts `files/<name>` to
/// `context/<name>.md`; the thread is archived when the job ends.
public actor FileConverter {
    private let noteFolderURL: URL
    private let runner: CodexWorkerTurnRunner
    /// Absolute path of the bundled anydoc CLI; nil when running without the
    /// app bundle (tests, spikes). The template then gets the bare word
    /// `anydoc`, which fails fast in the sandbox and routes the agent to
    /// INGEST.md's fallback tools — degraded, never failing.
    private let anydocPath: String?
    /// INGEST.md's template text, fetched per job so edits apply to the
    /// next conversion without an app restart. `{{ file }}` is the
    /// imported file's name.
    private let instructionsTemplate: @Sendable () -> String

    public init(
        noteFolderURL: URL, client: AppServerClient, model: String? = nil,
        effort: String? = nil,
        turnTimeout: Duration = .seconds(900),  // generous — odd formats send the agent exploring
        anydocPath: String? = nil,
        shouldArchiveOnJobEnd: @escaping @Sendable (String) async -> Bool = { _ in true },
        instructionsTemplate: @escaping @Sendable () -> String = {
            AgentInstructions.ingest.defaultContents
        }
    ) {
        self.noteFolderURL = noteFolderURL
        self.anydocPath = anydocPath
        self.instructionsTemplate = instructionsTemplate
        self.runner = CodexWorkerTurnRunner(
            client: client,
            spec: .init(
                cwd: noteFolderURL, sandbox: "workspace-write", writableRoot: noteFolderURL,
                model: model, effort: effort, turnTimeout: turnTimeout,
                shouldArchiveOnEnd: shouldArchiveOnJobEnd))
    }

    private func instructions(fileName: String) -> String {
        Self.renderInstructions(
            instructionsTemplate(), fileName: fileName, anydocPath: anydocPath)
    }

    /// Pure render step, split out for testability.
    nonisolated static func renderInstructions(
        _ template: String, fileName: String, anydocPath: String?
    ) -> String {
        AgentInstructions.render(
            template, variables: ["file": fileName, "anydoc": anydocPath ?? "anydoc"])
    }

    /// The anydoc CLI bundled at Contents/Helpers/anydoc, when running
    /// inside the app (dev builds in DerivedData and installed releases
    /// alike); nil headless.
    public nonisolated static var bundledAnydocPath: String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/anydoc")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    /// Converts one imported file end-to-end; returns when `context/` holds
    /// the result. `onThreadStarted` fires as soon as the thread id is known
    /// so the caller can persist it (SPEC.md §5.1: state.json records thread
    /// ids). The thread is archived on the way out, success or failure.
    public func convert(
        fileName: String, onThreadStarted: @Sendable (String) async -> Void = { _ in }
    ) async throws {
        let message = try await runner.run(
            instructions: instructions(fileName: fileName),
            threadName: "[simbi] convert: \(fileName)",
            onThreadStarted: onThreadStarted)
        if let message, let reason = CodexWorkerTurnRunner.reportedFailure(in: message) {
            throw CodexWorkerError.reportedFailure(reason)
        }

        let output = NoteLayout.contextURL(noteFolder: noteFolderURL, fileName: fileName)
        let size =
            (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw CodexWorkerError.noOutput }
    }
}
