import AppKit
@preconcurrency import OutlineViewKit
import SimbiKit

extension NSPasteboard.PasteboardType {
    /// Internal drag type for sidebar rows; payload is the node's path.
    static let simbiSidebarItem = NSPasteboard.PasteboardType("com.simbi.sidebar-item")
}

/// Sidebar row for OutlineViewKit: a truncating name label (no icon).
/// An `NSTableCellView` (not SwiftUI) because the outline view uses the
/// cell's `textField` outlet for selection tinting.
final class SidebarCellView: NSTableCellView {
    init(node: FileTreeNode) {
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: node.name)
        label.lineBreakMode = .byTruncatingTail
        if node.kind == .folder {
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        }
        addSubview(label)
        textField = label

        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// `NSMenuItem` that runs a closure, so sidebar context menus can be built
/// inline without a shared target object.
final class HandlerMenuItem: NSMenuItem {
    private var handler: @MainActor () -> Void = {}

    convenience init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    // NSMenuItem is not statically MainActor-isolated, but menu actions
    // fire on the main thread, so the action itself can be.
    @objc @MainActor private func invoke() { handler() }
}

/// Handles drops on the sidebar: internal drags of notes, folders, and loose
/// files, moved on disk (cross-folder) or reordered (same folder) by
/// `FileTreeModel.move`. AppKit delivers every callback on the main thread,
/// hence the `@preconcurrency` conformance.
@MainActor
final class SidebarDropReceiver: @preconcurrency DropReceiver {
    typealias DataElement = FileTreeNode

    private let model: FileTreeModel

    init(model: FileTreeModel) {
        self.model = model
    }

    func readPasteboard(item: NSPasteboardItem) -> DraggedItem<FileTreeNode>? {
        guard let path = item.string(forType: .simbiSidebarItem),
            let node = Self.node(atPath: path, in: model.nodes)
        else { return nil }
        return (node, .simbiSidebarItem)
    }

    func validateDrop(target: DropTarget<FileTreeNode>) -> ValidationResult<FileTreeNode> {
        // Leaf rows can't take children — retarget the drop to their parent.
        if let into = target.intoElement, into.kind != .folder {
            return .moveRedirect(item: parentFolder(of: into), childIndex: nil)
        }
        let folderPath = (target.intoElement?.url ?? model.home.rootURL)
            .standardizedFileURL.path
        for dragged in target.items {
            let itemPath = dragged.item.url.standardizedFileURL.path
            // A folder can't move into itself or its own subtree.
            if itemPath == folderPath || folderPath.hasPrefix(itemPath + "/") {
                return .deny
            }
        }
        return .move
    }

    func acceptDrop(target: DropTarget<FileTreeNode>) -> Bool {
        var folder = model.home.rootURL
        var childIndex = target.childIndex
        if let into = target.intoElement {
            if into.kind == .folder {
                folder = into.url
            } else {
                // Redirected drop on a leaf: land next to it in its parent.
                folder = into.url.deletingLastPathComponent()
                childIndex = nil
            }
        }
        model.move(target.items.map { $0.item.url }, into: folder, at: childIndex)
        return true
    }

    private func parentFolder(of node: FileTreeNode) -> FileTreeNode? {
        let parentPath = node.url.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath != model.home.rootURL.standardizedFileURL.path else { return nil }
        return Self.node(atPath: parentPath, in: model.nodes)
    }

    /// Path-based lookup: sturdier than URL equality, which trips over
    /// trailing-slash differences between scanned and reconstructed URLs.
    private static func node(atPath path: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.url.standardizedFileURL.path == path { return node }
            if let children = node.children, let hit = Self.node(atPath: path, in: children) {
                return hit
            }
        }
        return nil
    }
}
