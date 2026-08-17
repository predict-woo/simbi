import CodexKit
import Foundation
import Observation
import SimbiKit

/// Auto-titles one note: when a recording stops (transcript drained) and
/// the note still carries the default "New Note" name, a one-shot
/// NoteTitler thread proposes a title and the folder is renamed through
/// the sidebar's rename path. Failures are silent by design — the note
/// simply keeps its default name (degraded Codex is never a failure).
/// Shared per note like SummaryController so a run survives view
/// recreation.
@MainActor
@Observable
public final class TitleController {
    private static let controllers = PerNoteRegistry<TitleController>()

    public static func shared(noteFolderURL: URL) -> TitleController {
        controllers.value(for: noteFolderURL, make: TitleController.init(noteFolderURL:))
    }

    private(set) var working = false

    let noteFolderURL: URL
    private let titler: NoteTitler

    /// Renames the note folder — assigned by the note view, routed
    /// through FileTreeModel so sidebar order and selection follow.
    var renameNote: ((String) -> Void)?

    /// Whether the note's other Codex jobs are finished — assigned by the
    /// note view from the fixer's activity model and the summary status.
    /// The rename waits for this: the fixer and summarizer hold absolute
    /// paths into the note folder, so moving it under them strands their
    /// output (or resurrects the old folder via their writable roots).
    var noteIsQuiet: (() -> Bool)?

    /// Generous bound on the quiet wait: the fixer reviews its remaining
    /// cues after recording stop and a long session takes minutes. On
    /// timeout the rename is skipped — the note keeps its default name
    /// and the next recording stop retries.
    var quietWaitTimeout: Duration = .seconds(300)
    var quietPollInterval: Duration = .milliseconds(500)

    init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let choice = SimbiSettings.current()[.title]
        self.titler = NoteTitler(
            noteFolderURL: noteFolderURL, client: CodexServices.appServer,
            model: choice.model, effort: choice.effort)
    }

    /// The shared live availability model — the same source the note
    /// view's degraded banner and the sidebar footer observe.
    var codexAvailable: Bool {
        CodexSetupModel.shared.state == .connected
    }

    /// Quiet means no in-flight job holds paths into the note folder:
    /// the fixer has reviewed everything (or never ran) and no summary
    /// generation is running.
    nonisolated static func isQuiet(
        fixerStatus: FixerActivityModel.Status, summaryWorking: Bool
    ) -> Bool {
        (fixerStatus == .off || fixerStatus == .done) && !summaryWorking
    }

    /// A note the user (or a previous run) has renamed is never touched;
    /// otherwise the same gates as AI notes: cues exist, Codex works, no
    /// run in flight, no active recording.
    nonisolated static func shouldAutoGenerate(
        titleIsDefault: Bool, transcriptHasCues: Bool, codexAvailable: Bool,
        alreadyWorking: Bool, recordingActive: Bool
    ) -> Bool {
        titleIsDefault && transcriptHasCues && codexAvailable && !alreadyWorking
            && !recordingActive
    }

    /// The recording controller's clean-stop hook.
    func recordingDidStop() {
        guard
            Self.shouldAutoGenerate(
                titleIsDefault: NoteOperations.isDefaultNoteName(noteFolderURL.lastPathComponent),
                transcriptHasCues: VTT.transcriptHasCues(noteFolder: noteFolderURL),
                codexAvailable: codexAvailable,
                alreadyWorking: working,
                recordingActive: RecordingController.isCapturing(noteFolderURL: noteFolderURL))
        else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let title = try await titler.generateTitle()
                await awaitQuietThenApply(title)
            } catch {
                Log.ui.error("titling failed for \(noteFolderURL.lastPathComponent): \(error)")
            }
        }
    }

    /// The title is generated eagerly (its thread only reads), but the
    /// rename waits until the note is quiet. A restarted recording ends
    /// the wait early; `applyGeneratedTitle` then rejects the rename and
    /// the next stop starts over with the fuller transcript.
    func awaitQuietThenApply(_ title: String) async {
        let ended = await TranscriptDrainWait.wait(
            timeout: quietWaitTimeout, pollInterval: quietPollInterval
        ) { [weak self] in
            guard let self else { return true }
            return await self.quietOrAbandoned()
        }
        guard ended else {
            Log.ui.info("note never went quiet, keeping default name")
            return
        }
        applyGeneratedTitle(title, currentFolderName: noteFolderURL.lastPathComponent)
    }

    private func quietOrAbandoned() -> Bool {
        RecordingController.isCapturing(noteFolderURL: noteFolderURL)
            || (noteIsQuiet?() ?? true)
    }

    /// Applies a generated title, re-checking that the note is still on
    /// its default name — a rename by the user (or anything else) during
    /// the run wins, and a restarted recording defers to its own stop.
    /// Collisions dedupe to "Title 2" style rather than failing.
    func applyGeneratedTitle(_ title: String, currentFolderName: String) {
        guard NoteOperations.isDefaultNoteName(currentFolderName),
            !RecordingController.isCapturing(noteFolderURL: noteFolderURL),
            let renameNote
        else { return }
        let unique = NoteOperations.availableName(
            title, in: noteFolderURL.deletingLastPathComponent())
        renameNote(unique)
    }
}
