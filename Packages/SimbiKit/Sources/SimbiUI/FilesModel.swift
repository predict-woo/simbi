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
    private var watcher: FileTreeWatcher?

    private var filesURL: URL { noteFolderURL.appending(path: "files") }

    func contextURL(for name: String) -> URL {
        noteFolderURL.appending(path: "context/\(name).md")
    }

    private init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        self.converter = FileConverter(
            noteFolderURL: noteFolderURL, client: CodexServices.appServer)
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

    func refresh() {
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: filesURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        let state = (try? NoteRecordingState.load(noteFolder: noteFolderURL)) ?? .init()
        rows = names.map { name in
            let hasContext = FileManager.default.fileExists(
                atPath: contextURL(for: name).path)
            if activeJobs.contains(name) {
                return Row(name: name, status: .converting, hasContext: hasContext)
            }
            switch state.conversions[name]?.status {
            case .failed:
                return Row(name: name, status: .failed, hasContext: hasContext)
            case .done where hasContext:
                return Row(name: name, status: .done, hasContext: true)
            default:
                // New file, a "converting" record from a run that died, or a
                // done record whose context file was deleted → (re)convert.
                dispatch(name)
                return Row(name: name, status: .converting, hasContext: hasContext)
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
