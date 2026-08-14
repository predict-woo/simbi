import AppKit
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
            !FileManager.default.fileExists(atPath: selection.path)
        {
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

    /// "New Note" with a name prompt (SPEC.md §6): the dialog opens with
    /// the default name prefilled and selected, so typing replaces it;
    /// Return creates, Esc cancels.
    public func promptForNewNote(in folder: URL? = nil) {
        let parent = folder ?? targetFolderForNewItems
        let suggested = NoteOperations.availableNoteName(in: parent)
        guard let entered = NoteNamePrompt.run(suggestedName: suggested) else { return }
        // "/" would silently nest the note; an emptied field falls back to
        // the default name rather than failing.
        var name =
            entered
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        if name.isEmpty {
            name = suggested
        }
        name = NoteOperations.availableName(name, in: parent)
        if let url = try? NoteOperations.createNote(named: name, in: parent) {
            refresh()
            selection = url
        }
    }

    public func createFolder(in folder: URL? = nil) {
        let parent = folder ?? targetFolderForNewItems
        let name = NoteOperations.availableName("New Folder", in: parent)
        if (try? NoteOperations.createFolder(named: name, in: parent)) != nil {
            refresh()
        }
    }

    public func rename(_ url: URL, to newName: String) {
        if let renamed = try? NoteOperations.rename(url, to: newName) {
            SidebarOrder.renamed(
                from: url.lastPathComponent,
                to: renamed.lastPathComponent,
                in: url.deletingLastPathComponent()
            )
            // Retarget before refresh(): the folder is already moved, so
            // refresh() would see the stale selection pointing at a path
            // that no longer exists and clear it — closing the open note
            // on every rename of the selected note.
            retargetSelection(from: url, to: renamed)
            refresh()
        }
    }

    public func trash(_ url: URL) {
        try? NoteOperations.trash(url)
        SidebarOrder.removed(url.lastPathComponent, in: url.deletingLastPathComponent())
        refresh()
    }

    /// Moves `sources` into `folder` (the home root included), inserting at
    /// `childIndex` within the folder's displayed children (nil = append).
    /// Same-parent drops just reorder; cross-folder drops move on disk.
    /// Both persist the folder's order via `SidebarOrder`.
    public func move(_ sources: [URL], into folder: URL, at childIndex: Int?) {
        let folderPath = folder.standardizedFileURL.path
        let children =
            folderPath == home.rootURL.standardizedFileURL.path
            ? nodes
            : FileTreeNode.find(folder, in: nodes)?.children ?? []
        var names = children.map(\.name)
        var insertAt = childIndex.map { min(max($0, 0), names.count) } ?? names.count

        var movedNames: [String] = []
        for source in sources {
            let sourcePath = source.standardizedFileURL.path
            // Never drop a folder onto itself or into its own subtree.
            guard sourcePath != folderPath,
                !folderPath.hasPrefix(sourcePath + "/")
            else { continue }
            let sourceParent = source.deletingLastPathComponent()
            if sourceParent.standardizedFileURL.path == folderPath {
                if let old = names.firstIndex(of: source.lastPathComponent) {
                    names.remove(at: old)
                    if old < insertAt { insertAt -= 1 }
                }
                movedNames.append(source.lastPathComponent)
            } else {
                let name = NoteOperations.availableName(source.lastPathComponent, in: folder)
                let destination = folder.appending(path: name)
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                } catch {
                    continue
                }
                SidebarOrder.removed(source.lastPathComponent, in: sourceParent)
                movedNames.append(name)
                retargetSelection(from: source, to: destination)
            }
        }
        guard !movedNames.isEmpty else { return }
        names.insert(contentsOf: movedNames, at: insertAt)
        SidebarOrder.write(names, in: folder)
        refresh()
    }

    /// Keeps the selection pointing at a moved item — including one nested
    /// inside a moved folder.
    private func retargetSelection(from source: URL, to destination: URL) {
        guard let selection else { return }
        let selectedPath = selection.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        if selectedPath == sourcePath {
            self.selection = destination
        } else if selectedPath.hasPrefix(sourcePath + "/") {
            let suffix = String(selectedPath.dropFirst(sourcePath.count + 1))
            self.selection = destination.appending(path: suffix)
        }
    }
}

/// Native name prompt for New Note. NSAlert (not SwiftUI `.alert`) because
/// a SwiftUI alert TextField caches its text from the first presentation
/// and later prompts open empty; NSAlert also guarantees the AppKit
/// behaviors the dialog relies on — initial first responder selects the
/// whole prefill, Return fires the default button, Esc cancels.
@MainActor
enum NoteNamePrompt {
    /// Returns the entered name, or nil on cancel.
    static func run(suggestedName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "New Note"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: suggestedName)
        field.frame = NSRect(x: 0, y: 0, width: 230, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
