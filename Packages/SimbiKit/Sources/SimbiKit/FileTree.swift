import Foundation

/// One row in the sidebar tree. The tree mirrors the actual directory
/// structure under `~/Simbi` (SPEC.md §2.1) — no database, no index.
public struct FileTreeNode: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        /// An organizational folder (no `note.md`).
        case folder
        /// A note folder (contains `note.md`). Always a leaf in the tree.
        case note
        /// A loose regular file.
        case file
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    /// `nil` for leaves (notes and files); `[]` for an empty folder.
    public let children: [FileTreeNode]?

    public var id: URL { url }

    public init(url: URL, name: String, kind: Kind, children: [FileTreeNode]?) {
        self.url = url
        self.name = name
        self.kind = kind
        self.children = children
    }

    /// Depth-first search for the node with the given id.
    public static func find(_ id: URL, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let hit = find(id, in: children) {
                return hit
            }
        }
        return nil
    }

    /// True if any note exists anywhere in the tree — the welcome pane
    /// shows until this is true. Folders and loose files don't count.
    public static func containsNote(in nodes: [FileTreeNode]) -> Bool {
        for node in nodes {
            if node.kind == .note { return true }
            if let children = node.children, containsNote(in: children) {
                return true
            }
        }
        return false
    }
}

/// Scans a directory into `FileTreeNode`s.
///
/// Rules (SPEC.md §2.2):
/// - a folder containing `note.md` is a note folder and a **leaf** — its
///   internals (`files/`, `context/`, `.simbi/`, …) are never children;
/// - hidden entries are skipped;
/// - folders sort before loose files, each group alphabetically —
///   unless the folder has a manual `SidebarOrder`, which wins.
public enum FileTreeScanner {
    public static let noteMarkerName = "note.md"

    /// App-managed files that never show in the sidebar: the agent
    /// instruction files bootstrap writes to the home root (SPEC.md §2.1).
    /// Edited from Settings, not the note list.
    static let reservedNames: Set<String> = Set(
        AgentInstructions.allCases.map(\.fileName))

    public static func isNoteFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: noteMarkerName).path)
    }

    public static func scan(root: URL) -> [FileTreeNode] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        else {
            return []
        }

        var folders: [FileTreeNode] = []
        var files: [FileTreeNode] = []
        for entry in entries {
            let url = entry.standardizedFileURL
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = url.lastPathComponent
            if reservedNames.contains(name) { continue }
            if isDirectory {
                if isNoteFolder(url) {
                    folders.append(FileTreeNode(url: url, name: name, kind: .note, children: nil))
                } else {
                    folders.append(FileTreeNode(url: url, name: name, kind: .folder, children: scan(root: url)))
                }
            } else {
                files.append(FileTreeNode(url: url, name: name, kind: .file, children: nil))
            }
        }

        let byName: (FileTreeNode, FileTreeNode) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let defaultOrder = folders.sorted(by: byName) + files.sorted(by: byName)
        return SidebarOrder.apply(to: defaultOrder, in: root)
    }
}
