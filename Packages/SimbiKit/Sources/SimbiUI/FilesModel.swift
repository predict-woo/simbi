import CodexKit
import Foundation
import Observation
import SimbiKit

/// Coalesces parallel file conversions into one context-ready event. A picker
/// selection dispatches all of its files synchronously, so the transition back
/// to zero active jobs is the batch boundary the rest of the app cares about.
struct ContextConversionBatch {
    private var active = 0
    private var successful = 0

    mutating func started() {
        active += 1
    }

    /// Returns the successful-file count exactly once when the batch settles.
    mutating func finished(successfully: Bool) -> Int? {
        precondition(active > 0)
        active -= 1
        if successfully { successful += 1 }
        guard active == 0 else { return nil }
        defer { successful = 0 }
        return successful > 0 ? successful : nil
    }
}

/// Owns file import + conversion for one note (SPEC.md §5.3): copies
/// dropped/picked files into `files/`, dispatches one converter thread per
/// file, and exposes per-row status for the UI. Shared per note (like
/// RecordingController) so conversions survive view recreation.
@MainActor
@Observable
final class FilesModel {
    struct FileRevision: Hashable {
        let modifiedAt: Date?
        let size: Int?
        let fileIdentifier: Data?
    }

    struct Row: Identifiable {
        let name: String
        let status: NoteRecordingState.FileConversion.Status
        let threadId: String?
        let fileRevision: FileRevision
        var id: String { name }
    }

    private static let models = PerNoteRegistry<FilesModel>()

    static func shared(noteFolderURL: URL) -> FilesModel {
        models.value(for: noteFolderURL) { FilesModel(noteFolderURL: $0) }
    }

    private(set) var rows: [Row] = []
    private(set) var importError: String?

    /// Fired once after all conversions in an import batch settle, carrying
    /// the number that produced usable context. If the note view has not
    /// attached its handler yet, the completed count is retained and delivered
    /// when it does (fast conversions must not miss the AI-notes trigger).
    var onContextBatchCompleted: ((Int) -> Void)? {
        didSet { deliverPendingContextBatchIfPossible() }
    }

    private let noteFolderURL: URL
    private let converter: FileConverter
    private var activeJobs: Set<String> = []
    private var conversionBatch = ContextConversionBatch()
    private var pendingCompletedContextFiles = 0
    /// Files whose conversion thread is running a turn the app did not
    /// start (typed in a viewer terminal). Suppresses refresh()'s
    /// stale-record re-dispatch while the turn runs; empty after a
    /// relaunch, so crash recovery behaves exactly as before.
    private var externalTurns: Set<String> = []
    private var watcher: FileTreeWatcher?

    private var filesURL: URL { NoteLayout.filesDirURL(noteFolder: noteFolderURL) }

    func contextURL(for name: String) -> URL {
        NoteLayout.contextURL(noteFolder: noteFolderURL, fileName: name)
    }

    func fileURL(for name: String) -> URL {
        filesURL.appending(path: name)
    }

    /// All conversion-status writes funnel through here so a failed
    /// state.json save is logged instead of silently dropped.
    private nonisolated static func updateState(
        noteFolder: URL, _ mutate: (inout NoteRecordingState) -> Void
    ) {
        do {
            try NoteRecordingState.update(noteFolder: noteFolder, mutate)
        } catch {
            Log.files.error(
                "updating conversion state for \(noteFolder.lastPathComponent) failed: \(error)")
        }
    }

    private init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let choice = SimbiSettings.current()[.converter]
        self.converter = FileConverter(
            noteFolderURL: noteFolderURL, client: CodexServices.appServer,
            model: choice.model, effort: choice.effort,
            anydocPath: FileConverter.bundledAnydocPath,
            shouldArchiveOnJobEnd: { threadId in
                !(await ThreadViewerManager.shared.isOpen(threadId: threadId))
            },
            // Read INGEST.md per job so edits apply without a restart.
            instructionsTemplate: {
                AgentInstructions.ingest.contents(homeRootURL: SimbiHome().rootURL)
            })
        refresh()
        // Watch the note folder so external drops into files/ and converter
        // output in context/ show up live.
        watcher = FileTreeWatcher.observing(url: noteFolderURL) { [weak self] in
            self?.refresh()
        }
        Task { [weak self] in
            await CodexServices.appServer.addNotificationHandler { [weak self] method, params in
                guard method == "turn/started" || method == "turn/completed" else { return }
                Task { @MainActor [weak self] in
                    self?.handleThreadEvent(method: method, params: params)
                }
            }
        }
    }

    /// Live-view spec §5: status follows the thread. turn/started on a
    /// known converter thread shows converting; turn/completed re-verifies
    /// the output file — done when context/<name>.md is non-empty, failed
    /// otherwise. App-owned jobs (activeJobs) keep their own bookkeeping.
    private func handleThreadEvent(method: String, params: Data) {
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        guard
            let effect = ConversionThreadEvents.effect(
                method: method, params: params,
                conversions: state.conversions, activeJobs: activeJobs)
        else { return }
        switch effect {
        case .turnBegan(let file):
            if externalTurns.insert(file).inserted {
                conversionBatch.started()
            }
            Self.updateState(noteFolder: noteFolderURL) {
                $0.conversions[file]?.status = .converting
            }
        case .turnEnded(let file):
            let done = WorkerOutput.exists(at: contextURL(for: file))
            let wasTracked = externalTurns.remove(file) != nil
            Self.updateState(noteFolder: noteFolderURL) {
                $0.conversions[file]?.status = done ? .done : .failed
            }
            if wasTracked { conversionFinished(successfully: done) }
        }
        refresh()
    }

    /// Copies files into `files/` under collision-free names; the originals
    /// are never modified. Conversion is dispatched by the refresh pass.
    func importFiles(_ urls: [URL]) {
        do {
            try FileManager.default.createDirectory(
                at: filesURL, withIntermediateDirectories: true)
            for url in urls {
                let name = NoteOperations.availableFileName(url.lastPathComponent, in: filesURL)
                try FileManager.default.copyItem(at: url, to: filesURL.appending(path: name))
            }
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
        refresh()
    }

    /// Right-click → View Codex Thread: attach a viewer terminal to the
    /// file's conversion thread (live-view spec §4).
    func openThreadViewer(_ name: String) {
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        guard let threadId = state.conversions[name]?.threadId else { return }
        ThreadViewerManager.shared.open(
            threadId: threadId, title: "Conversion: \(name)", noteFolderURL: noteFolderURL,
            archivesOnClose: true,
            isBusy: { [weak self] in
                guard let self else { return false }
                return self.activeJobs.contains(name) || self.externalTurns.contains(name)
            })
    }

    func retry(_ name: String) {
        Self.updateState(noteFolder: noteFolderURL) {
            $0.conversions[name] = nil
        }
        refresh()
    }

    /// Trashes the original and its converted markdown, and clears the
    /// conversion record so a re-added file with the same name converts
    /// fresh. Trash (not unlink) so a slip is recoverable, like Finder.
    func delete(_ name: String) {
        for url in [fileURL(for: name), contextURL(for: name)]
        where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                Log.files.error("trashing \(url.lastPathComponent) failed: \(error)")
            }
        }
        Self.updateState(noteFolder: noteFolderURL) {
            $0.conversions[name] = nil
        }
        refresh()
    }

    func refresh() {
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: filesURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        rows = names.map { name in
            let fileRevision = Self.fileRevision(at: fileURL(for: name))
            let hasContext = FileManager.default.fileExists(
                atPath: contextURL(for: name).path)
            let threadId = state.conversions[name]?.threadId
            if activeJobs.contains(name) || externalTurns.contains(name) {
                return Row(
                    name: name, status: .converting, threadId: threadId,
                    fileRevision: fileRevision)
            }
            switch state.conversions[name]?.status {
            case .failed:
                return Row(
                    name: name, status: .failed, threadId: threadId,
                    fileRevision: fileRevision)
            case .done where hasContext:
                return Row(
                    name: name, status: .done, threadId: threadId,
                    fileRevision: fileRevision)
            default:
                // New file, a "converting" record from a run that died, or a
                // done record whose context file was deleted → (re)convert.
                dispatch(name)
                return Row(
                    name: name, status: .converting, threadId: threadId,
                    fileRevision: fileRevision)
            }
        }
    }

    private static func fileRevision(at url: URL) -> FileRevision {
        let values = try? url.resourceValues(
            forKeys: [
                .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
            ])
        return FileRevision(
            modifiedAt: values?.contentModificationDate,
            size: values?.fileSize,
            fileIdentifier: values?.fileResourceIdentifier as? Data)
    }

    private func dispatch(_ name: String) {
        activeJobs.insert(name)
        conversionBatch.started()
        Self.updateState(noteFolder: noteFolderURL) {
            $0.conversions[name] = .init(status: .converting)
        }
        Task {
            let folder = noteFolderURL
            var converted = false
            do {
                try await converter.convert(fileName: name) { threadId in
                    Self.updateState(noteFolder: folder) {
                        $0.conversions[name]?.threadId = threadId
                    }
                }
                Self.updateState(noteFolder: folder) {
                    $0.conversions[name] = .init(
                        status: .done, threadId: $0.conversions[name]?.threadId)
                }
                converted = true
            } catch {
                Log.files.error("converting \(name) failed: \(error)")
                Self.updateState(noteFolder: folder) {
                    $0.conversions[name] = .init(
                        status: .failed, threadId: $0.conversions[name]?.threadId)
                }
            }
            activeJobs.remove(name)
            conversionFinished(successfully: converted)
            refresh()
        }
    }

    private func conversionFinished(successfully: Bool) {
        guard let completed = conversionBatch.finished(successfully: successfully) else { return }
        pendingCompletedContextFiles += completed
        deliverPendingContextBatchIfPossible()
    }

    private func deliverPendingContextBatchIfPossible() {
        guard let onContextBatchCompleted, pendingCompletedContextFiles > 0 else { return }
        let completed = pendingCompletedContextFiles
        pendingCompletedContextFiles = 0
        onContextBatchCompleted(completed)
    }
}
