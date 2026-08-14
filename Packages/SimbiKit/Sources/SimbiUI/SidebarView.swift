import AppKit
@preconcurrency import OutlineViewKit
import SimbiKit
import SwiftUI

/// The file tree over `~/Simbi`. Notes are leaves with a distinct icon;
/// context menu offers the plain FS operations (SPEC.md §6).
///
/// Rendered with the vendored OutlineViewKit (`NSOutlineView`) rather than
/// SwiftUI `List`/`OutlineGroup`, which on macOS supports neither dragging
/// rows between folders nor manual reordering. Order edits persist via
/// `SidebarOrder`.
struct SidebarView: View {
    @Bindable var model: FileTreeModel

    @State private var renameTarget: FileTreeNode?
    @State private var renameText = ""

    var body: some View {
        OutlineView(
            model.nodes,
            children: \.children,
            selection: selectedNode
        ) { node in
            SidebarCellView(node: node)
        }
        .outlineViewStyle(.sourceList)
        .quietRowSelection()
        // Folders are containers, not documents: clicking one toggles its
        // expansion, and the selection only ever points at notes and files.
        .selectableRows { $0.kind != .folder }
        .dragDataSource { node in
            let item = NSPasteboardItem()
            item.setString(node.url.standardizedFileURL.path, forType: .simbiSidebarItem)
            return item
        }
        .onDrop(of: [.simbiSidebarItem], receiver: SidebarDropReceiver(model: model))
        .contextMenu { node in
            contextMenu(for: node)
        }
        .overlay {
            if model.nodes.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "square.and.pencil",
                    description: Text("Create your first note with ⌘N.")
                )
            }
        }
        .alert("Rename", isPresented: renameAlertPresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget, !renameText.isEmpty {
                    model.rename(target.url, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var selectedNode: Binding<FileTreeNode?> {
        Binding(
            get: { model.selectedNode },
            set: { model.selection = $0?.url }
        )
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { presented in
                if !presented { renameTarget = nil }
            }
        )
    }

    /// Per-row context menu; `nil` node means the empty area below the rows,
    /// which acts on the home root.
    private func contextMenu(for node: FileTreeNode?) -> NSMenu {
        let menu = NSMenu()
        guard let node else {
            menu.addItem(HandlerMenuItem("New Note") { model.promptForNewNote() })
            menu.addItem(HandlerMenuItem("New Folder") { model.createFolder() })
            return menu
        }
        if node.kind == .folder {
            menu.addItem(
                HandlerMenuItem("New Note") {
                    model.promptForNewNote(in: node.url)
                })
            menu.addItem(
                HandlerMenuItem("New Folder") {
                    model.createFolder(in: node.url)
                })
            menu.addItem(.separator())
        }
        menu.addItem(
            HandlerMenuItem("Rename…") {
                renameText = node.name
                renameTarget = node
            })
        menu.addItem(
            HandlerMenuItem("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            })
        menu.addItem(.separator())
        menu.addItem(HandlerMenuItem("Move to Trash") { model.trash(node.url) })
        return menu
    }
}
