import AppKit
import SimbiKit
import SwiftUI

/// The file tree over `~/Simbi`. Notes are leaves with a distinct icon;
/// context menu offers the plain FS operations (SPEC.md §6).
struct SidebarView: View {
    @Bindable var model: FileTreeModel

    @State private var renameTarget: FileTreeNode?
    @State private var renameText = ""

    var body: some View {
        List(selection: $model.selection) {
            OutlineGroup(model.nodes, children: \.children) { node in
                row(for: node)
            }
        }
        .contextMenu {
            // Empty-area menu: act on the home root.
            Button("New Note") { model.createNote() }
            Button("New Folder") { model.createFolder() }
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

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { presented in
                if !presented { renameTarget = nil }
            }
        )
    }

    @ViewBuilder
    private func row(for node: FileTreeNode) -> some View {
        Label(node.name, systemImage: icon(for: node))
            .tag(node.url)
            .contextMenu {
                if node.kind == .folder {
                    Button("New Note") {
                        model.selection = node.url
                        model.createNote()
                    }
                    Button("New Folder") {
                        model.selection = node.url
                        model.createFolder()
                    }
                    Divider()
                }
                Button("Rename…") {
                    renameText = node.name
                    renameTarget = node
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    model.trash(node.url)
                }
            }
    }

    private func icon(for node: FileTreeNode) -> String {
        switch node.kind {
        case .folder: "folder"
        case .note: "doc.text"
        case .file: "doc"
        }
    }
}
