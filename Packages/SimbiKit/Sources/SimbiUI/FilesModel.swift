import CodexKit
import Foundation
import Observation
import SimbiKit

/// Owns file import + conversion for one note (SPEC.md §5.3): copies
/// dropped/picked files into `files/`, dispatches one converter thread per
/// file, and exposes per-row status for the UI. Shared per note (like
/// RecordingController) so conversions survive view recreation.
@MainActor
@Observable
final class FilesModel {
    struct Row: Identifiable {
        let name: String
        let status: NoteRecordingState.FileConversion.Status
        let threadId: String?
        var id: String { name }
    }

    private static let models = PerNoteRegistry<FilesModel>()

    static func shared(noteFolderURL: URL) -> FilesModel {
        models.value(for: noteFolderURL) { FilesModel(noteFolderURL: $0) }
    }

    private(set) var rows: [Row] = []
    private(set) var importError: String?

    private let noteFolderURL: URL
    private let converter: FileConverter
    private var activeJobs: Set<String> = []
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
            externalTurns.insert(file)
            Self.updateState(noteFolder: noteFolderURL) {
                $0.conversions[file]?.status = .converting
            }
        case .turnEnded(let file):
            externalTurns.remove(file)
            let done = WorkerOutput.exists(at: contextURL(for: file))
            Self.updateState(noteFolder: noteFolderURL) {
                $0.conversions[file]?.status = done ? .done : .failed
            }
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
            let hasContext = FileManager.default.fileExists(
                atPath: contextURL(for: name).path)
            let threadId = state.conversions[name]?.threadId
            if activeJobs.contains(name) || externalTurns.contains(name) {
                return Row(name: name, status: .converting, threadId: threadId)
            }
            switch state.conversions[name]?.status {
            case .failed:
                return Row(name: name, status: .failed, threadId: threadId)
            case .done where hasContext:
                return Row(name: name, status: .done, threadId: threadId)
            default:
                // New file, a "converting" record from a run that died, or a
                // done record whose context file was deleted → (re)convert.
                dispatch(name)
                return Row(name: name, status: .converting, threadId: threadId)
            }
        }
    }

    private func dispatch(_ name: String) {
        activeJobs.insert(name)
        Self.updateState(noteFolder: noteFolderURL) {
            $0.conversions[name] = .init(status: .converting)
        }
        Task {
            let folder = noteFolderURL
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
            } catch {
                Log.files.error("converting \(name) failed: \(error)")
                Self.updateState(noteFolder: folder) {
                    $0.conversions[name] = .init(
                        status: .failed, threadId: $0.conversions[name]?.threadId)
                }
            }
            activeJobs.remove(name)
            refresh()
        }
    }
}
