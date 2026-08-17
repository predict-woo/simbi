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
    /// How far the sidebar outline is scrolled past its resting top, in
    /// points. Drives the top fade so a first row at rest isn't dimmed.
    @State private var sidebarScrollOverflow: CGFloat = 0
    /// Built lazily so a completed first run never constructs the wizard
    /// (whose init starts the model download).
    @State private var onboardingModel: OnboardingModel?
    private var onboardingPresenter = OnboardingPresenter.shared

    public init() {}

    public var body: some View {
        // While onboarding is active, the wizard IS the window: the main
        // content's `.task` (home bootstrap, model warm-up) must not run
        // until the wizard has persisted the folder choice, because
        // `SimbiHome.activeRootURL` latches on first access.
        if onboardingPresenter.isActive {
            Group {
                if let model = onboardingModel {
                    OnboardingView(model: model)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .onAppear {
                if onboardingModel == nil { onboardingModel = OnboardingModel() }
            }
            .onChange(of: onboardingModel?.completed ?? false) { _, done in
                if done { onboardingModel = nil }
            }
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            // A plain stack, not a safeAreaInset: the inset's default
            // spacing made the gap above the footer text visibly larger
            // than the one below it.
            VStack(spacing: 0) {
                SidebarView(model: model)
                    .background(SidebarScrollProbe(overflow: $sidebarScrollOverflow))
                    // Rows fade out under the title bar and above the footer
                    // instead of clipping mid-glyph at a hard edge. The top
                    // fade tracks the scroll position and vanishes at rest,
                    // where there is nothing above to fade and it would only
                    // dim the first row.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(1 - sidebarTopFade), .black],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: Design.paneInset)
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

    /// Strength of the top fade, 0...1: full once the content has scrolled
    /// one fade-height past rest, proportional inside that range so the
    /// gradient eases in with the scroll rather than popping.
    private var sidebarTopFade: Double {
        Double(min(max(sidebarScrollOverflow / Design.paneInset, 0), 1))
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

/// Reports how far the sidebar outline's clip view is scrolled past its
/// resting top, in points. OutlineViewKit exposes no scroll position, so
/// this sits behind `SidebarView` and observes the `NSScrollView` directly.
private struct SidebarScrollProbe: NSViewRepresentable {
    @Binding var overflow: CGFloat

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onOverflowChange = { overflow = $0 }
    }

    final class ProbeView: NSView {
        var onOverflowChange: ((CGFloat) -> Void)?
        private weak var clipView: NSClipView?
        private var lastReported: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // The outline's scroll view is a sibling subtree that may not
            // be in the hierarchy yet on this pass; retry a runloop later.
            if !attachIfPossible() {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.attachIfPossible()
                }
            }
        }

        private func attachIfPossible() -> Bool {
            guard let clip = locateOutlineClipView() else { return false }
            guard clip !== clipView else { return true }
            clipView = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
            // Deferred so the first report never lands mid view-update.
            DispatchQueue.main.async { [weak self] in self?.report() }
            return true
        }

        @objc private func boundsChanged() {
            report()
        }

        private func report() {
            guard let clip = clipView else { return }
            // At rest the clip view's bounds sit at -contentInsets.top
            // (the automatic title-bar inset), so this is zero at the top.
            let overflow = clip.bounds.origin.y + clip.contentInsets.top
            guard overflow != lastReported else { return }
            lastReported = overflow
            onOverflowChange?(overflow)
        }

        /// Nearest ancestor subtree wins, so this finds the sidebar's own
        /// outline before it could ever reach another pane's scroll view.
        private func locateOutlineClipView() -> NSClipView? {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = Self.outlineScrollView(in: view) {
                    return scroll.contentView
                }
                ancestor = view.superview
            }
            return nil
        }

        private static func outlineScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSOutlineView {
                return scroll
            }
            for subview in view.subviews {
                if let found = outlineScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}

/// Degraded-state indicator (SPEC.md §6): recording still works without
/// Codex; transcription and intelligence don't.
private struct CodexStatusFooter: View {
    var body: some View {
        let available = CodexSetupModel.shared.state == .connected
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
