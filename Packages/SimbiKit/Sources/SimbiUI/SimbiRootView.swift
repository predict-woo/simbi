import CodexKit
import SimbiAudio
import SimbiKit
import SwiftUI

/// The app's root: sidebar file tree | note editor | transcript pane.
public struct SimbiRootView: View {
    @State private var model = FileTreeModel()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
                .safeAreaInset(edge: .bottom) {
                    CodexStatusFooter()
                }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem {
                Button("New Note", systemImage: "square.and.pencil") {
                    model.promptForNewNote()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        // Name prompt for every New Note entry point (toolbar, ⌘N, sidebar
        // context menus). The field auto-focuses with the dated default
        // selected, so typing replaces it; Return creates.
        .alert("New Note", isPresented: noteCreationPresented) {
            TextField("Name", text: $model.noteNameDraft)
            Button("Create") { model.confirmNoteCreation() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.cancelNoteCreation() }
        }
        .task {
            model.start()
            // Load the diarizer + VAD models now so Record never waits on
            // them (screenshot mode stays offline).
            if !Design.uiPreview {
                SpeechModelPool.shared.warmUp()
            }
        }
    }

    private var noteCreationPresented: Binding<Bool> {
        Binding(
            get: { model.noteCreationParent != nil },
            set: { presented in
                if !presented { model.cancelNoteCreation() }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let node = model.selectedNode, node.kind == .note {
            // .id() recreates the document state when the selection changes.
            NoteView(noteFolderURL: node.url)
                .id(node.url)
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "doc.text",
                description: Text("Choose a note in the sidebar, or create one with ⌘N.")
            )
        }
    }
}

/// Degraded-state indicator (SPEC.md §6): recording still works without
/// Codex; transcription and intelligence don't.
private struct CodexStatusFooter: View {
    private let installation = CodexInstallation.standard

    var body: some View {
        let available = installation.isBinaryInstalled && installation.loadAuth() != nil
        HStack(spacing: 6) {
            Circle()
                .fill(available ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(available ? "Codex connected" : "Codex unavailable — transcription off")
                .font(.meta)
                .foregroundStyle(available ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
