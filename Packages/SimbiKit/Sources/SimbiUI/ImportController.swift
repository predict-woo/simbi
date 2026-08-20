import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// Owns the media-import pipeline for one note: a FIFO of files/ names,
/// one import at a time, mutual exclusion with the recorder in both
/// directions (media-import spec). Shared per note like RecordingController.
@MainActor
@Observable
public final class ImportController {
    public enum Status: Equatable {
        case idle
        case importing(file: String, detail: String)
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
    let noteFolderURL: URL
    private let pipeline: ImportPipeline
    private var queue: [String] = []
    /// The file the worker task currently owns; enqueue dedups against it
    /// (the queue alone can't — pump pops the name before the import's
    /// state.json record lands, and a refresh() in that window would
    /// re-enqueue and import the file twice).
    private var current: String?

    private init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        self.pipeline = ImportPipeline(
            noteFolderURL: noteFolderURL,
            transcriber: CodexTranscriber(),
            decoder: MediaFileDecoder(),
            analyzer: OfflineSpeechAnalyzer())
        // Relaunch recovery: a phase-1 marker rolls back; a phase-2 marker
        // resumes uploading in the background.
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        if let active = state.activeImport {
            if active.phase == 1 {
                do {
                    try ImportPipeline.rollbackStalePhase1(noteFolder: noteFolderURL)
                } catch {
                    Log.files.error("rolling back stale import failed: \(error)")
                }
            } else {
                let file = active.fileName
                status = .importing(file: file, detail: "Resuming transcription")
                Task { [pipeline] in
                    do {
                        try await pipeline.resumePhase2()
                    } catch {
                        Log.files.error("resuming import of \(file) failed: \(error)")
                    }
                    self.status = .idle
                }
            }
        }
    }

    /// Queues a files/ entry for import (dedup; no-op while already queued
    /// or running).
    func enqueue(_ fileName: String) {
        guard !queue.contains(fileName), current != fileName else { return }
        queue.append(fileName)
        pump()
    }

    /// Clears a failed record so the file re-imports.
    func retry(_ fileName: String) {
        do {
            try NoteRecordingState.update(noteFolder: noteFolderURL) {
                $0.imports[fileName] = nil
            }
        } catch {
            Log.files.error("clearing import record for \(fileName) failed: \(error)")
        }
        enqueue(fileName)
    }

    private func pump() {
        guard current == nil, let fileName = queue.first else { return }
        current = fileName
        queue.removeFirst()
        Task {
            // The recorder owns the note while capturing; wait it out.
            while RecordingController.isCapturing(noteFolderURL: noteFolderURL) {
                status = .importing(file: fileName, detail: "Waiting for recording to stop")
                try? await Task.sleep(for: .seconds(2))
            }
            status = .importing(file: fileName, detail: "Analyzing")
            let progressTask = Task { [pipeline] in
                for await progress in await pipeline.progressUpdates() {
                    self.status = .importing(
                        file: progress.fileName, detail: Self.detail(progress.stage))
                }
            }
            do {
                try await pipeline.run(fileName: fileName)
            } catch {
                Log.files.error("import of \(fileName) failed: \(error)")
            }
            progressTask.cancel()
            status = .idle
            current = nil
            pump()
        }
    }

    private static func detail(_ stage: ImportPipeline.Progress.Stage) -> String {
        switch stage {
        case .analyzing(let seconds):
            return "Analyzing: \(Int(seconds / 60))m \(Int(seconds) % 60)s decoded"
        case .transcribing(let done, let total):
            return "Transcribing \(done) of \(total)"
        case .finished:
            return "Finished"
        case .failed:
            return "Failed"
        }
    }
}
