import AppKit
@preconcurrency import OutlineViewKit
import SimbiKit

extension NSPasteboard.PasteboardType {
    /// Internal drag type for sidebar rows; payload is the node's path.
    static let simbiSidebarItem = NSPasteboard.PasteboardType("com.simbi.sidebar-item")
}

/// Sidebar row for OutlineViewKit: a truncating name label with compact
/// hover actions. Pinned rows keep the pin action visible as a state marker.
/// An `NSTableCellView` (not SwiftUI) because the outline view uses the
/// cell's `textField` outlet for selection tinting.
@MainActor
final class SidebarCellView: NSTableCellView, OutlineViewRowHoverable {
    private let deleteButton: SidebarDeleteButton
    private let pinButton: SidebarPinButton
    private let actions: NSStackView

    init(
        node: FileTreeNode,
        isPinned: Bool,
        onTogglePin: @escaping @MainActor () -> Void,
        onDelete: @escaping @MainActor () -> Void
    ) {
        deleteButton = SidebarDeleteButton(nodeName: node.name, handler: onDelete)
        pinButton = SidebarPinButton(
            nodeName: node.name, isPinned: isPinned, handler: onTogglePin)
        actions = NSStackView(views: [pinButton, deleteButton])
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: node.name)
        label.lineBreakMode = .byTruncatingTail
        // A long name must never widen the row: the label yields to the
        // cell bounds (low resistance + hard trailing pin) and shows an
        // ellipsis instead of running under the sidebar's edge.
        label.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        if node.kind == .folder {
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        }
        addSubview(label)
        textField = label

        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(actions)

        label.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setOutlineViewHovered(_ hovered: Bool) {
        pinButton.setHovered(hovered)
        deleteButton.setHovered(hovered)
    }
}

/// A compact pin/unpin affordance. Unpinned rows reveal it on hover; pinned
/// rows keep it visible so the pin state is clear without relying on color.
@MainActor
private final class SidebarPinButton: NSButton {
    private let handler: @MainActor () -> Void
    private let nodeName: String
    private var pinned: Bool
    private var hovered = false

    init(nodeName: String, isPinned: Bool, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.nodeName = nodeName
        self.pinned = isPinned
        super.init(frame: .zero)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        contentTintColor = .secondaryLabelColor
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        target = self
        action = #selector(invoke)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    func setHovered(_ hovered: Bool) {
        self.hovered = hovered
        updateVisibility()
    }

    private func updateAppearance() {
        image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? "Unpin from top" : "Pin to top")
        let action = pinned ? "Unpin" : "Pin"
        toolTip = "\(action) \(nodeName) \(pinned ? "from" : "to") top"
        setAccessibilityLabel("\(action) \(nodeName) \(pinned ? "from" : "to") top")
        updateVisibility()
    }

    private func updateVisibility() {
        isHidden = !pinned && !hovered
    }

    @objc private func invoke() {
        pinned.toggle()
        updateAppearance()
        handler()
    }
}

/// A compact, visible delete affordance for every sidebar row. Deletion uses
/// FileManager.trashItem, so users can recover recordings from macOS Trash.
@MainActor
private final class SidebarDeleteButton: NSButton {
    private let handler: @MainActor () -> Void

    init(nodeName: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: "trash.fill",
            accessibilityDescription: "Move to Trash")
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        contentTintColor = .systemRed
        isHidden = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        toolTip = "Move \(nodeName) to Trash"
        setAccessibilityLabel("Move \(nodeName) to Trash")
        target = self
        action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }

    func setHovered(_ hovered: Bool) {
        isHidden = !hovered
    }

    @objc private func invoke() { handler() }
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
