import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// Owns the media-import pipeline for one note: uploaded files become the
/// note's recording (decoded into audio.webm + transcript.vtt; the original
/// is read in place, never copied into the note). One import at a time,
/// mutual exclusion with the recorder in both directions (media-import
/// spec). Shared per note like RecordingController.
@MainActor
@Observable
public final class ImportController {
    public enum Status: Equatable {
        case idle
        case importing(file: String, detail: String)
        /// Shown in the empty transcript state; cleared by the next upload.
        case failed(message: String)
    }

    private static let controllers = PerNoteRegistry<ImportController>()

    public static func shared(noteFolderURL: URL) -> ImportController {
        controllers.value(for: noteFolderURL, make: ImportController.init(noteFolderURL:))
    }

    /// True while THIS note is importing. Read-only; never creates a
    /// controller as a side effect. The recorder reads it to refuse
    /// starting while an import owns the note's timeline (state.json's
    /// sessionCount/totalSamples have a single writer at a time).
    static func isImporting(noteFolderURL: URL) -> Bool {
        if case .importing = controllers[noteFolderURL]?.status { return true }
        return false
    }

    public private(set) var status: Status = .idle
    /// True while an import is still writing audio.webm (decode phase):
    /// the playback bar must stay hidden then — the timeline is growing
    /// under the player. False from the diarizing stage on (audio final).
    public private(set) var decodingAudio = false
    /// Fired after an import fully completes (uploads drained, fixer pass
    /// done) — the note view routes it into the same summary/title
    /// triggers a stopped recording fires.
    var onImportFinished: (() -> Void)?
    /// True while the end-of-import fixer pass runs; the strip shows the
    /// sparkles button then, and the thread viewer reads it as busy.
    private(set) var fixingTranscript = false
    let noteFolderURL: URL
    private let pipeline: ImportPipeline
    private var queue: [URL] = []
    /// The file the worker task currently owns; upload requests dedup
    /// against it (the queue alone can't — pump pops the URL before the
    /// import's state.json record lands, and a second request in that
    /// window would import the file twice).
    private var current: String?

    private init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        self.pipeline = ImportPipeline(
            noteFolderURL: noteFolderURL,
            transcriber: CodexTranscriber(),
            decoder: MediaFileDecoder(),
            analyzer: OfflineSpeechAnalyzer())
        recoverLeftoverImportIfNeeded()
    }

    /// Recovery for a marker left by a crash or an in-session failure: a
    /// phase-1 marker rolls back; a phase-2 marker resumes uploading in
    /// the background — the pipeline refuses to run over a leftover
    /// phase-2 marker (`resumePending`), so the drain must be kicked
    /// before any new import. No-op while an import owns the worker slot:
    /// the marker then belongs to the running import, not to a leftover.
    private func recoverLeftoverImportIfNeeded() {
        guard current == nil else { return }
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        guard let active = state.activeImport else { return }
        if active.phase == 1 {
            do {
                try ImportPipeline.rollbackStalePhase1(noteFolder: noteFolderURL)
            } catch {
                Log.files.error("rolling back stale import failed: \(error)")
            }
        } else {
            let file = active.fileName
            // The resume owns the worker machinery exactly like a
            // normal import: holding `current` makes an upload during
            // the resume defer into the queue instead of colliding
            // with the pipeline's running flag, and status stays
            // .importing for the whole drain so the recorder guard
            // keeps holding.
            current = file
            status = .importing(file: file, detail: "Resuming transcription")
            Task { [pipeline] in
                do {
                    try await pipeline.resumePhase2()
                } catch {
                    Log.files.error("resuming import of \(file) failed: \(error)")
                }
                self.status = .idle
                self.current = nil
                self.pump()
            }
        }
    }

    /// The empty state's Upload Audio button: validates the format, then
    /// queues the file to become the note's recording. Failures land in
    /// `status` for the pane; pressing the button again is the retry.
    func startUpload(fileURL: URL) {
        guard MediaFileDecoder.kind(of: fileURL.lastPathComponent) == .supported else {
            status = .failed(
                message: "This format is not supported. Choose an audio or video file.")
            return
        }
        let name = fileURL.lastPathComponent
        guard !queue.contains(where: { $0.lastPathComponent == name }), current != name
        else { return }
        if case .failed = status { status = .idle }
        // A leftover phase-2 marker (a previous import died after
        // committing audio) drains first; the new upload queues behind it.
        recoverLeftoverImportIfNeeded()
        queue.append(fileURL)
        pump()
    }

    private func pump() {
        guard current == nil, let fileURL = queue.first else { return }
        let fileName = fileURL.lastPathComponent
        current = fileName
        queue.removeFirst()
        Task {
            // The recorder owns the note while capturing; wait it out.
            while RecordingController.isCapturing(noteFolderURL: noteFolderURL) {
                status = .importing(file: fileName, detail: "Waiting for recording to stop")
                try? await Task.sleep(for: .seconds(2))
            }
            status = .importing(file: fileName, detail: "Analyzing")
            // Fixer per settings, exactly like RecordingController.start():
            // reuse the note's saved thread unless the instructions
            // changed; disabled = nil = the pipeline skips the pass.
            let settings = SimbiSettings.current()
            if settings.transcriptFixerEnabled {
                let noteState = NoteRecordingState.current(noteFolder: noteFolderURL)
                let fixerInstructions = AgentInstructions.fixer.resolve(
                    homeRootURL: SimbiHome().rootURL)
                let savedThreadId =
                    noteState.fixerInstructionsVersion == TranscriptFixer.instructionsVersion
                        && noteState.fixerInstructionsHash
                            == AgentInstructions.fingerprint(fixerInstructions)
                    ? noteState.fixerThreadId : nil
                let choice = settings[.fixer]
                await pipeline.attachFixer(
                    TranscriptFixer(
                        noteFolderURL: noteFolderURL, client: CodexServices.appServer,
                        savedThreadId: savedThreadId, model: choice.model,
                        effort: choice.effort, instructions: fixerInstructions))
            } else {
                await pipeline.attachFixer(nil)
            }
            decodingAudio = true
            let progressTask = Task { [pipeline] in
                for await progress in await pipeline.progressUpdates() {
                    if case .analyzing = progress.stage {
                        self.decodingAudio = true
                    } else {
                        self.decodingAudio = false
                    }
                    self.fixingTranscript = progress.stage == .fixing
                    self.status = .importing(
                        file: progress.fileName, detail: Self.detail(progress.stage))
                }
            }
            var failure: String?
            do {
                try await pipeline.run(fileURL: fileURL)
            } catch {
                Log.files.error("import of \(fileName) failed: \(error)")
                failure = Self.failureMessage(for: error, fileName: fileName)
            }
            progressTask.cancel()
            // Drain any delivered update before committing the final UI state.
            await progressTask.value
            decodingAudio = false
            fixingTranscript = false
            status = failure.map { .failed(message: $0) } ?? .idle
            current = nil
            if failure == nil {
                onImportFinished?()
            }
            pump()
        }
    }

    /// The strip's sparkles button during the end-of-import fixer pass:
    /// opens the note's fixer thread in the live viewer — the same thread
    /// (and the same viewer contract) as the recorder's fixer button.
    /// Fixer viewers never archive on close; the thread stays resumable.
    func openFixerViewer() {
        guard let threadId = NoteRecordingState.current(noteFolder: noteFolderURL).fixerThreadId
        else { return }
        ThreadViewerManager.shared.open(
            threadId: threadId,
            title: "Fixer: \(noteFolderURL.lastPathComponent)",
            noteFolderURL: noteFolderURL,
            archivesOnClose: false,
            isBusy: { [weak self] in self?.fixingTranscript ?? false })
    }

    private static func failureMessage(for error: Error, fileName: String) -> String {
        switch error as? ImportPipelineError {
        case .noAudio:
            return "\(fileName) has no audio to import."
        case .recordingRecoveryPending:
            return "This note has an interrupted recording. Press Record once to recover it, then upload."
        case .resumePending, .importAlreadyRunning:
            return "Another import is still finishing. Try again in a moment."
        case .audioFileMismatch:
            return "The note's audio file does not match its records. Import is disabled for this note."
        case nil:
            if error is MediaFileDecoderError {
                return "\(fileName) could not be decoded. Choose an audio or video file."
            }
            return "Importing \(fileName) failed: \(error.localizedDescription)"
        }
    }

    private static func detail(_ stage: ImportPipeline.Progress.Stage) -> String {
        switch stage {
        case .analyzing(let seconds):
            return "Analyzing: \(Int(seconds / 60))m \(Int(seconds) % 60)s decoded"
        case .diarizing:
            return "Identifying speakers"
        case .transcribing(let done, let total):
            return "Transcribing \(done) of \(total)"
        case .fixing:
            return "Fixing transcript"
        case .finished:
            return "Finished"
        case .failed:
            return "Failed"
        }
    }
}
