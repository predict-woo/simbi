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

    /// "New Note" with a name prompt (SPEC.md §6): the dialog opens with
    /// the dated default prefilled and selected, so typing replaces it;
    /// Return creates, Esc cancels.
    public func promptForNewNote() {
        let parent = targetFolderForNewItems
        let suggested = NoteOperations.availableNoteName(in: parent)
        guard let entered = NoteNamePrompt.run(suggestedName: suggested) else { return }
        // "/" would silently nest the note; an emptied field falls back to
        // the dated default rather than failing.
        var name = entered
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
