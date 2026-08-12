import CodexKit
import SimbiAudio
import SimbiKit
import SwiftUI

/// The app's root: sidebar file tree | note editor | transcript pane.
public struct SimbiRootView: View {
    @State private var model = FileTreeModel()
    /// The note actually shown in the detail pane. Follows `model.selection`
    /// asynchronously (see the `.task(id:)` below) so a sidebar click paints
    /// its highlight immediately instead of waiting on NoteView construction.
    @State private var openNoteURL: URL?

    public init() {}

    public var body: some View {
        NavigationSplitView {
            // A plain stack, not a safeAreaInset: the inset's default
            // spacing made the gap above the footer text visibly larger
            // than the one below it.
            VStack(spacing: 0) {
                SidebarView(model: model)
                    // Rows fade out above the footer instead of clipping
                    // mid-glyph at a hard edge.
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: Design.paneInset)
                        }
                    }
                UpdatePill(model: UpdateModel.shared)
                CodexStatusFooter()
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 240)
        } detail: {
            // Same floor as NoteView's split so the window minimum doesn't
            // change with selection (the no-note placeholder has no
            // intrinsic width of its own).
            detail
                .frame(minWidth: 480, minHeight: 280)
        }
        .toolbar {
            ToolbarItem {
                Button("New Note", systemImage: "square.and.pencil") {
                    model.promptForNewNote()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        // Creating the shared client at launch arms AppServerJanitor's
        // quit cleanup: quitting must kill every running codex server —
        // including older sessions' orphans — even if this session never
        // talks to codex. (No server is spawned by this; that stays lazy.)
        .task { _ = CodexServices.appServer }
        // Decouple opening a note from clicking it: building NoteView (five
        // models, file reads, the markdown parse) is the expensive part, so
        // it runs a beat after the selection change. The short sleep lets the
        // sidebar highlight paint first, and — because `.task(id:)` cancels
        // on every selection change — rapid clicking coalesces to only ever
        // build the last-clicked note. The previous note stays visible while
        // the next one builds.
        .task(id: model.selection) {
            let target = model.selectedNode
            guard target?.kind == .note else {
                openNoteURL = nil
                return
            }
            guard target?.url != openNoteURL else { return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            openNoteURL = target?.url
        }
        .task {
            model.start()
            // Load the diarizer + VAD models now so Record never waits on
            // them (screenshot mode stays offline).
            if !Flags.uiPreview {
                SpeechModelPool.shared.warmUp()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let url = openNoteURL {
            // .id() recreates the document state when the open note changes.
            NoteView(
                noteFolderURL: url,
                renameNote: { model.rename(url, to: $0) }
            )
            .id(url)
        } else if !FileTreeNode.containsNote(in: model.nodes) || Flags.uiPreviewWelcome {
            WelcomeView(createNote: { model.promptForNewNote() })
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
        Button {
            CodexStatusWindowManager.shared.open()
        } label: {
            HStack(spacing: Design.iconGap) {
                StatusDot(color: available ? .statusOK : .statusWarning)
                Text(available ? "Codex connected" : "Codex unavailable: transcription off")
                    .font(.meta)
                    .foregroundStyle(
                        available ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.statusWarning)
                    )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.footerInset)
            .padding(.vertical, Design.stripPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show Codex account status and usage")
    }
}
