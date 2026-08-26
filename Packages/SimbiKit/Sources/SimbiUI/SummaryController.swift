import CodexKit
import Foundation
import Observation
import SimbiKit

/// Owns AI-notes generation for one note (AI Notes spec §3): triggers the
/// NoteSummarizer and exposes tab-strip state. summary.md is written by
/// the summarizer thread directly (deliberate, for extensibility; user
/// decision 2026-08-10) — the app only reads it, reloading the open
/// editor via generationCount. Shared per note like RecordingController
/// so a generation survives view recreation.
@MainActor
@Observable
public final class SummaryController {
    public enum Status: Equatable {
        case idle
        case working
        case failed(String)
    }

    private static let controllers = PerNoteRegistry<SummaryController>()

    public static func shared(noteFolderURL: URL) -> SummaryController {
        controllers.value(for: noteFolderURL, make: SummaryController.init(noteFolderURL:))
    }

    private(set) var status: Status = .idle
    /// Bumps after each successful generation; the note view reloads the
    /// AI Notes document (rewritten on disk by the summarizer thread)
    /// when it changes.
    private(set) var generationCount = 0
    /// True while a run that began with no summary.md on disk is in
    /// flight. This — not the watcher-backed summaryExists — is what keeps
    /// the first-generation placeholder up: the thread writes summary.md
    /// mid-turn, seconds before the turn completes and generationCount
    /// reloads the editor, so a placeholder keyed to the file's existence
    /// dropped early and flashed an empty editor across that gap.
    private(set) var firstGenerationInFlight = false

    let noteFolderURL: URL
    private let summarizer: NoteSummarizer

    init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let choice = SimbiSettings.current()[.summary]
        self.summarizer = NoteSummarizer(
            noteFolderURL: noteFolderURL, client: CodexServices.appServer,
            model: choice.model, effort: choice.effort)
        self.summaryExists = FileManager.default.fileExists(
            atPath: NoteLayout.summaryURL(noteFolder: noteFolderURL).path)
        self.transcriptHasCues = VTT.transcriptHasCues(noteFolder: noteFolderURL)
        watcher = FileTreeWatcher.observing(url: noteFolderURL) { [weak self] in
            self?.refreshFileState()
        }
    }

    /// Internal (not private) so tests can drive the watcher path
    /// synchronously.
    func refreshFileState() {
        let summaryExisted = summaryExists
        summaryExists = FileManager.default.fileExists(atPath: summaryFileURL.path)
        transcriptHasCues = VTT.transcriptHasCues(noteFolder: noteFolderURL)
        // Filesystem is truth: an external delete of summary.md (Finder,
        // git, a chat thread) must tell the note view to drop the editor's
        // held text, or closing the note resurrects the file. Idle-only:
        // the fresh-regenerate delete lands here with status already
        // .working (or .failed), and there the held text is the documented
        // failed-run recovery.
        if summaryExisted && !summaryExists && status == .idle {
            summaryFileRemovedExternally?()
        }
    }

    /// The note view's hook to drop its AI-notes editor text after an
    /// external delete; nil once the view is gone (nothing holds text then).
    var summaryFileRemovedExternally: (() -> Void)?

    var summaryFileURL: URL { NoteLayout.summaryURL(noteFolder: noteFolderURL) }

    /// Flushes any pending debounced editor autosaves so the summarizer
    /// thread reads current note.md/summary.md from disk. Assigned by the
    /// note view, which owns the documents; nil when the note is closed —
    /// that path already flushed both documents in onDisappear.
    var flushEditorsBeforeGenerate: (() -> Void)?

    /// Whether summary.md is on disk — its mere existence makes the tab
    /// strip appear. Stored and watcher-refreshed so external creates and
    /// deletes (Finder, git, a chat thread) flip the strip live, not just
    /// in-app generations.
    private(set) var summaryExists: Bool

    /// Whether the transcript on disk has at least one cue — stored and
    /// watcher-refreshed like summaryExists, so late-draining uploads and
    /// external edits flip the first-generation offer live.
    private(set) var transcriptHasCues: Bool

    private var watcher: FileTreeWatcher?

    /// The shared live availability model — the same source the note
    /// view's degraded banner and the sidebar footer observe.
    var codexAvailable: Bool {
        CodexSetupModel.shared.state == .connected
    }

    /// Degraded or empty recordings never auto-generate (spec §3); a run
    /// already in flight is never doubled; an active recording never
    /// triggers (spec §3: no trigger while recording).
    nonisolated static func shouldAutoGenerate(
        enabled: Bool, transcriptHasCues: Bool, codexAvailable: Bool, alreadyWorking: Bool,
        recordingActive: Bool
    ) -> Bool {
        enabled && transcriptHasCues && codexAvailable && !alreadyWorking && !recordingActive
    }

    /// Whether the note view offers a first-generation button (issue #3):
    /// the note has a transcript worth summarizing but no AI notes and no
    /// run in flight — the states where the tab strip (and so the
    /// regenerate button) doesn't exist yet. Codex availability is
    /// deliberately absent: like the regenerate button, the offer shows
    /// disabled with an explanatory tooltip when Codex is degraded.
    nonisolated static func shouldOfferFirstGeneration(
        enabled: Bool, transcriptHasCues: Bool, summaryExists: Bool, statusIdle: Bool,
        recordingActive: Bool
    ) -> Bool {
        enabled && transcriptHasCues && !summaryExists && statusIdle && !recordingActive
    }

    /// The offer predicate over this note's live state.
    var canOfferFirstGeneration: Bool {
        Self.shouldOfferFirstGeneration(
            enabled: SimbiSettings.current().aiNotesEnabled,
            transcriptHasCues: transcriptHasCues, summaryExists: summaryExists,
            statusIdle: status == .idle,
            recordingActive: RecordingController.isCapturing(noteFolderURL: noteFolderURL))
    }

    /// The first-generation button. Same guards as retry(); nothing to
    /// delete, and beginRun() detects first-ness from disk so the
    /// placeholder and tab strip appear through the existing paths.
    func generateFirst() {
        guard SimbiSettings.current().aiNotesEnabled, status != .working, codexAvailable,
            !RecordingController.isCapturing(noteFolderURL: noteFolderURL)
        else { return }
        generate()
    }

    /// The recording controller's clean-stop hook.
    func recordingDidStop() {
        let hasCues = VTT.transcriptHasCues(noteFolder: noteFolderURL)
        guard
            Self.shouldAutoGenerate(
                enabled: SimbiSettings.current().aiNotesEnabled,
                transcriptHasCues: hasCues, codexAvailable: codexAvailable,
                alreadyWorking: status == .working,
                recordingActive: RecordingController.isCapturing(noteFolderURL: noteFolderURL))
        else { return }
        generate()
    }

    /// The tab strip's regenerate button and the failed banner's Try
    /// Again. Refuses while this note is recording (spec §3) — the view
    /// gates its buttons too, but the guard here holds regardless.
    ///
    /// Manual regeneration starts over (user decision 2026-08-10): the old
    /// summary.md is deleted so the thread writes from scratch, discarding
    /// any hand edits. Only the recording-stop trigger updates in place.
    func regenerate() {
        guard SimbiSettings.current().aiNotesEnabled, status != .working, codexAvailable,
            !RecordingController.isCapturing(noteFolderURL: noteFolderURL)
        else { return }
        generate(fresh: true)
    }

    /// The failed banner's Try Again: repeats the attempt without deleting
    /// anything, so a failed in-place update stays an in-place update.
    func retry() {
        guard SimbiSettings.current().aiNotesEnabled, status != .working, codexAvailable,
            !RecordingController.isCapturing(noteFolderURL: noteFolderURL)
        else { return }
        generate()
    }

    /// A failed attempt keeps the strip (and its retry) alive only while
    /// the note stays open (spec §4).
    func clearFailureOnClose() {
        if case .failed = status {
            status = .idle
        }
    }

    private func generate(fresh: Bool = false) {
        // The open note's debounced autosaves must land on disk before
        // the turn starts: the thread reads note.md and summary.md there.
        flushEditorsBeforeGenerate?()
        // Fresh mode deletes AFTER the flush so a just-flushed editor write
        // can't resurrect the file; the open editor keeps the old text in
        // memory, so a failed run is recoverable by editing or closing the
        // note (both save the held text back to disk).
        if fresh, FileManager.default.fileExists(atPath: summaryFileURL.path) {
            do {
                try FileManager.default.removeItem(at: summaryFileURL)
            } catch {
                Log.ui.error("deleting summary.md for fresh generation failed: \(error)")
            }
        }
        beginRun()
        Task {
            do {
                try await summarizer.generate()
                finishRun()
            } catch {
                // The banner shows a fixed message; keep the real error
                // (including a thread-reported FAILED reason) in the log
                // for diagnosis.
                if case CodexWorkerError.reportedFailure(let reason) = error {
                    Log.ui.error(
                        "summarizer reported failure for \(noteFolderURL.lastPathComponent):"
                            + " \(reason)")
                } else {
                    Log.ui.error(
                        "summary generation failed for \(noteFolderURL.lastPathComponent):"
                            + " \(error)")
                }
                finishRun(failedWith: "AI notes couldn't be updated.")
            }
        }
    }

    /// The synchronous state flips that bracket a run, split from
    /// generate() so tests can drive a full run's transitions without a
    /// live app-server. First-ness is read from disk here, after any
    /// fresh-mode delete, so a regenerate counts as a first generation.
    func beginRun() {
        firstGenerationInFlight = !FileManager.default.fileExists(atPath: summaryFileURL.path)
        status = .working
    }

    func finishRun(failedWith message: String? = nil) {
        firstGenerationInFlight = false
        if let message {
            status = .failed(message)
        } else {
            generationCount += 1
            status = .idle
        }
    }

    // Test seams: status transitions without a live app-server.
    func markFailedForTesting(_ message: String) { status = .failed(message) }
    func markWorkingForTesting() { status = .working }
}
