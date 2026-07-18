import Foundation
import Observation
import SimbiKit

/// Sidebar state: the scanned tree, the selection, and the FSEvents-driven
/// live refresh. All mutation happens on the main actor; the watcher's
/// background callbacks arrive via an `AsyncStream`.
@MainActor
@Observable
public final class FileTreeModel {
    public let home: SimbiHome
    public private(set) var nodes: [FileTreeNode] = []
    public var selection: URL?
    public private(set) var bootstrapError: Error?

    private var watcher: FileTreeWatcher?
    private var watchTask: Task<Void, Never>?

    public init(home: SimbiHome = SimbiHome()) {
        self.home = home
    }

    public var selectedNode: FileTreeNode? {
        selection.flatMap { FileTreeNode.find($0, in: nodes) }
    }

    /// Bootstraps `~/Simbi`, scans it, and starts watching for changes.
    public func start() {
        do {
            try home.bootstrap()
        } catch {
            bootstrapError = error
        }
        refresh()

        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        watcher = FileTreeWatcher(url: home.rootURL) {
            continuation.yield()
        }
        watchTask = Task { [weak self] in
            for await _ in changes {
                self?.refresh()
            }
        }
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        watcher = nil
    }

    public func refresh() {
        nodes = FileTreeScanner.scan(root: home.rootURL)
        // Clear the selection only when the item is truly gone from disk —
        // a transient scan miss during heavy file churn (e.g. the recording
        // pipeline writing into the note folder) must not tear down the
        // selected note view mid-recording.
        if let selection, FileTreeNode.find(selection, in: nodes) == nil,
            !FileManager.default.fileExists(atPath: selection.path) {
            self.selection = nil
        }
    }

    /// The folder new items land in: the selected organizational folder, the
    /// parent of a selected leaf, or the home root.
    public var targetFolderForNewItems: URL {
        guard let node = selectedNode else { return home.rootURL }
        switch node.kind {
        case .folder:
            return node.url
        case .note, .file:
            return node.url.deletingLastPathComponent()
        }
    }

    /// "New Note" dialog state (SPEC.md §6): a non-nil parent presents the
    /// name prompt with `noteNameDraft` prefilled to the dated default.
    public private(set) var noteCreationParent: URL?
    public var noteNameDraft = ""

    public func promptForNewNote() {
        let parent = targetFolderForNewItems
        noteNameDraft = NoteOperations.availableNoteName(in: parent)
        noteCreationParent = parent
    }

    public func confirmNoteCreation() {
        guard let parent = noteCreationParent else { return }
        noteCreationParent = nil
        // "/" would silently nest the note; an emptied field falls back to
        // the dated default rather than failing.
        var name = noteNameDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        if name.isEmpty {
            name = NoteOperations.availableNoteName(in: parent)
        }
        name = NoteOperations.availableName(name, in: parent)
        if let url = try? NoteOperations.createNote(named: name, in: parent) {
            refresh()
            selection = url
        }
    }

    public func cancelNoteCreation() {
        noteCreationParent = nil
    }

    public func createFolder() {
        let parent = targetFolderForNewItems
        let name = NoteOperations.availableName("New Folder", in: parent)
        if (try? NoteOperations.createFolder(named: name, in: parent)) != nil {
            refresh()
        }
    }

    public func rename(_ url: URL, to newName: String) {
        if let renamed = try? NoteOperations.rename(url, to: newName) {
            refresh()
            if selection == url {
                selection = renamed
            }
        }
    }

    public func trash(_ url: URL) {
        try? NoteOperations.trash(url)
        refresh()
    }
}
