import CodexKit
import Foundation
import Observation
import SimbiKit

/// One app-server process for the whole app (SPEC.md §5.1), shared by every
/// feature that talks to Codex (fixer, converter, chat).
enum CodexServices {
    static let appServer = AppServerClient()
}

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
        let hasContext: Bool
        let threadId: String?
        var id: String { name }
    }

    private static var models: [URL: FilesModel] = [:]

    static func shared(noteFolderURL: URL) -> FilesModel {
        if let existing = models[noteFolderURL] { return existing }
        let model = FilesModel(noteFolderURL: noteFolderURL)
        models[noteFolderURL] = model
        return model
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

    private var filesURL: URL { noteFolderURL.appending(path: "files") }

    func contextURL(for name: String) -> URL {
        noteFolderURL.appending(path: "context/\(name).md")
    }

    func fileURL(for name: String) -> URL {
        filesURL.appending(path: name)
    }

    private init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let settings =
            (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
        self.converter = FileConverter(
            noteFolderURL: noteFolderURL, client: CodexServices.appServer,
            model: settings.converterModel,
            anydocPath: FileConverter.bundledAnydocPath,
            // Read INGEST.md per job so edits apply without a restart.
            instructionsTemplate: {
                AgentInstructions.ingest.contents(homeRootURL: SimbiHome().rootURL)
            })
        refresh()
        // Watch the note folder so external drops into files/ and converter
        // output in context/ show up live — same pattern as TranscriptModel.
        let (events, continuation) = AsyncStream.makeStream(of: Void.self)
        watcher = FileTreeWatcher(url: noteFolderURL) {
            continuation.yield()
        }
        Task { [weak self] in
            for await _ in events {
                self?.refresh()
            }
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
        let state = (try? NoteRecordingState.load(noteFolder: noteFolderURL)) ?? .init()
        guard
            let effect = ConversionThreadEvents.effect(
                method: method, params: params,
                conversions: state.conversions, activeJobs: activeJobs)
        else { return }
        switch effect {
        case .turnBegan(let file):
            externalTurns.insert(file)
            try? NoteRecordingState.update(noteFolder: noteFolderURL) {
                $0.conversions[file]?.status = .converting
            }
        case .turnEnded(let file):
            externalTurns.remove(file)
            let size =
                (try? FileManager.default.attributesOfItem(
                    atPath: contextURL(for: file).path)[.size] as? Int) ?? 0
            try? NoteRecordingState.update(noteFolder: noteFolderURL) {
                $0.conversions[file]?.status = size > 0 ? .done : .failed
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

    func retry(_ name: String) {
        try? NoteRecordingState.update(noteFolder: noteFolderURL) {
            $0.conversions[name] = nil
        }
        refresh()
    }

    /// Trashes the original and its converted markdown, and clears the
    /// conversion record so a re-added file with the same name converts
    /// fresh. Trash (not unlink) so a slip is recoverable, like Finder.
    func delete(_ name: String) {
        try? FileManager.default.trashItem(
            at: fileURL(for: name), resultingItemURL: nil)
        try? FileManager.default.trashItem(
            at: contextURL(for: name), resultingItemURL: nil)
        try? NoteRecordingState.update(noteFolder: noteFolderURL) {
            $0.conversions[name] = nil
        }
        refresh()
    }

    func refresh() {
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: filesURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        let state = (try? NoteRecordingState.load(noteFolder: noteFolderURL)) ?? .init()
        rows = names.map { name in
            let hasContext = FileManager.default.fileExists(
                atPath: contextURL(for: name).path)
            let threadId = state.conversions[name]?.threadId
            if activeJobs.contains(name) || externalTurns.contains(name) {
                return Row(
                    name: name, status: .converting, hasContext: hasContext,
                    threadId: threadId)
            }
            switch state.conversions[name]?.status {
            case .failed:
                return Row(
                    name: name, status: .failed, hasContext: hasContext,
                    threadId: threadId)
            case .done where hasContext:
                return Row(name: name, status: .done, hasContext: true, threadId: threadId)
            default:
                // New file, a "converting" record from a run that died, or a
                // done record whose context file was deleted → (re)convert.
                dispatch(name)
                return Row(
                    name: name, status: .converting, hasContext: hasContext,
                    threadId: threadId)
            }
        }
    }

    private func dispatch(_ name: String) {
        activeJobs.insert(name)
        try? NoteRecordingState.update(noteFolder: noteFolderURL) {
            $0.conversions[name] = .init(status: .converting)
        }
        Task {
            let folder = noteFolderURL
            do {
                try await converter.convert(fileName: name) { threadId in
                    try? NoteRecordingState.update(noteFolder: folder) {
                        $0.conversions[name]?.threadId = threadId
                    }
                }
                try? NoteRecordingState.update(noteFolder: folder) {
                    $0.conversions[name] = .init(
                        status: .done, threadId: $0.conversions[name]?.threadId)
                }
            } catch {
                try? NoteRecordingState.update(noteFolder: folder) {
                    $0.conversions[name] = .init(
                        status: .failed, threadId: $0.conversions[name]?.threadId)
                }
            }
            activeJobs.remove(name)
            refresh()
        }
    }
}
