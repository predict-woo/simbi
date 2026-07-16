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
        if let selection, FileTreeNode.find(selection, in: nodes) == nil {
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

    public func createNote() {
        let parent = targetFolderForNewItems
        let name = NoteOperations.availableNoteName(in: parent)
        if let url = try? NoteOperations.createNote(named: name, in: parent) {
            refresh()
            selection = url
        }
    }

    public func createFolder() {
        let parent = targetFolderForNewItems
        var name = "New Folder"
        var counter = 2
        while FileManager.default.fileExists(atPath: parent.appending(path: name).path) {
            name = "New Folder \(counter)"
            counter += 1
        }
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
