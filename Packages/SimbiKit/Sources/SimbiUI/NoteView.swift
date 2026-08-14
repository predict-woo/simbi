import AppKit
import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit
import SplitViewKit
import SwiftUI

/// Loads and autosaves one named markdown file in a note folder
/// (`note.md` by default; the AI Notes tab loads `summary.md`).
@MainActor
@Observable
final class NoteDocument {
    let noteFolderURL: URL
    let fileName: String
    var text: String

    private var saveTask: Task<Void, Never>?

    var fileURL: URL {
        noteFolderURL.appending(path: fileName)
    }

    init(noteFolderURL: URL, fileName: String = FileTreeScanner.noteMarkerName) {
        self.noteFolderURL = noteFolderURL
        let fileURL = noteFolderURL.appending(path: fileName)
        self.fileName = fileName
        self.text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Debounced autosave; a pending save is superseded by the next edit.
    func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        // Never materialize a missing file for empty content: the AI Notes
        // document saves on close like note.md does, but summary.md's mere
        // existence is state (it makes the tab strip appear), so a note
        // that never had AI notes must not gain an empty file.
        if text.isEmpty && !FileManager.default.fileExists(atPath: fileURL.path) { return }
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

/// The note view: title, `note.md` editor, recording controls and the live
/// transcript pane (SPEC.md §6).
struct NoteView: View {
    @State private var document: NoteDocument
    @State private var recorder: RecordingController
    @State private var transcript: TranscriptModel
    @State private var files: FilesModel
    @State private var playback: PlaybackController
    @State private var summary: SummaryController
    @State private var titleController: TitleController
    @State private var aiDocument: NoteDocument
    @State private var selectedTab: EditorTab = .myNotes
    @State private var transcriptFlash: CueFlash?
    @State private var renameDialogShown = false
    @State private var renameText = ""

    /// Renames the note folder — routed through FileTreeModel so the
    /// sidebar order and selection follow the folder to its new URL.
    let renameNote: (String) -> Void

    init(noteFolderURL: URL, renameNote: @escaping (String) -> Void) {
        self._document = State(initialValue: NoteDocument(noteFolderURL: noteFolderURL))
        self._recorder = State(initialValue: RecordingController.shared(noteFolderURL: noteFolderURL))
        self._transcript = State(initialValue: TranscriptModel(noteFolderURL: noteFolderURL))
        self._files = State(initialValue: FilesModel.shared(noteFolderURL: noteFolderURL))
        self._playback = State(initialValue: PlaybackController(noteFolderURL: noteFolderURL))
        self._summary = State(initialValue: SummaryController.shared(noteFolderURL: noteFolderURL))
        self._titleController = State(
            initialValue: TitleController.shared(noteFolderURL: noteFolderURL))
        self._aiDocument = State(
            initialValue: NoteDocument(noteFolderURL: noteFolderURL, fileName: "summary.md"))
        self.renameNote = renameNote
    }

    /// Pane floors in points (converted to fractions for SplitViewKit) and
    /// the initial divider position, matching the old 560/380 ideal split.
    private static let editorMinWidth: CGFloat = 260
    private static let transcriptMinWidth: CGFloat = 220
    private static let initialEditorFraction: CGFloat = 0.6

    /// The divider position, shared by every NoteView for the app
    /// session so the ratio survives note switches (spec
    /// 2026-08-11-shared-split-ratio). One stable instance is also what
    /// SplitViewKit needs: it resets its internal fraction whenever the
    /// holder's value changes between renders, so a holder rebuilt per
    /// view (the old @State) snapped the divider back to 0.6 on every
    /// note switch. Session-only by design — never persisted.
    @MainActor private static let sharedSplitFraction = FractionHolder(
        NoteView.initialEditorFraction)

    var body: some View {
        // Vendored SplitViewKit (pure SwiftUI), not HSplitView: the
        // macOS 26 NSSplitView bridge pins the window minimum at a bogus
        // constant, draws its divider through the glass titlebar, and
        // detaches from the trailing edge when the window shrinks after
        // a divider drag. See Sources/SplitViewKit/VENDORED.md. The
        // GeometryReader converts the pane floors (in points) to the
        // fractions SplitViewKit expects; the 481 floor keeps the
        // fractions sane before layout settles.
        GeometryReader { geo in
            let width = max(geo.size.width, 481)
            HSplit(left: { editorPane }, right: { transcriptPane })
                .fraction(Self.sharedSplitFraction)
                .constraints(
                    minPFraction: Self.editorMinWidth / width,
                    minSFraction: Self.transcriptMinWidth / width
                )
                .styling(color: .hairline, inset: 0, visibleThickness: 1, invisibleThickness: 9)
        }
        // The rule under the glass toolbar, tucked 1pt up so it coincides
        // with the titlebar scroll pocket's own bottom hairline. Content at
        // the top edge keeps that pocket alive; drawing our rule in the
        // same spot means exactly one 1pt line renders whether the pocket
        // is present (its line, ours behind the backdrop) or not (ours).
        .overlay(alignment: .top) {
            Hairline().offset(y: -1)
        }
        .frame(minWidth: 480)
        .navigationTitle(document.noteFolderURL.lastPathComponent)
        // Clicking the toolbar title opens the same rename dialog as the
        // sidebar's context menu. SwiftUI's binding navigationTitle is
        // documented to make the title editable but does nothing on macOS,
        // and replacing the title item wrecks the toolbar's flexible
        // layout — so an AppKit click hook on the title view it is.
        .background(
            ToolbarTitleClickCatcher {
                renameText = document.noteFolderURL.lastPathComponent
                renameDialogShown = true
            }
        )
        .alert("Rename", isPresented: $renameDialogShown) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if !renameText.isEmpty {
                    renameNote(renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .toolbar {
            ToolbarItem {
                chatButton
            }
            ToolbarItem {
                // Opening the folder itself (not selecting it in its
                // parent) lands Finder inside the note's contents. Lives
                // here, not in the root toolbar, so it exists only while
                // a note is open (same as the chat button).
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(document.noteFolderURL)
                }
                .help("Show this note's files in Finder")
            }
        }
        .onChange(of: document.text) {
            document.scheduleAutosave()
        }
        .onChange(of: aiDocument.text) {
            aiDocument.scheduleAutosave()
        }
        .onAppear {
            // Both controllers are app-lifetime; reassigning is idempotent.
            recorder.onRecordingStopped = { [weak summary, weak titleController] in
                summary?.recordingDidStop()
                titleController?.recordingDidStop()
            }
            titleController.renameNote = renameNote
            // Whatever triggers a generation (stop hook, regenerate, Try
            // Again), the controller flushes this view's debounced
            // autosaves before reading disk. Weak: once the view is gone
            // its documents were flushed by onDisappear, and the next
            // NoteView reassigns the hook with its own documents.
            summary.flushEditorsBeforeGenerate = { [weak document, weak aiDocument] in
                document?.saveNow()
                aiDocument?.saveNow()
            }
            // Opening a note that already has AI notes lands on them
            // (spec §4) — unless a recording is underway.
            if summary.summaryExists && recorder.status == .idle {
                selectedTab = .aiNotes
            }
        }
        // Starting a recording silences playback (speakers → mic feedback)
        // and forces My Notes — that's where live note-taking happens.
        .onChange(of: recorder.status) { _, status in
            if status != .idle {
                playback.pause()
            }
            if status == .recording {
                selectedTab = .myNotes
            }
        }
        // A generation starting pulls the AI Notes tab forward (spec §4).
        .onChange(of: summary.status) { _, status in
            if status == .working {
                selectedTab = .aiNotes
            }
        }
        .onChange(of: summary.generationCount) {
            // The summarizer thread just rewrote summary.md on disk;
            // refresh the open editor. Safe: the editor is hit-disabled
            // while working.
            aiDocument.text =
                (try? String(contentsOf: aiDocument.fileURL, encoding: .utf8)) ?? ""
        }
        // Recording deliberately continues if the view goes away (the
        // controller is shared per note); only the Stop button ends it.
        // Playback is view-local and does stop.
        .onDisappear {
            document.saveNow()
            aiDocument.saveNow()
            summary.clearFailureOnClose()
            playback.stop()
        }
    }

    /// Spec §4: the strip exists once AI notes exist, are being generated,
    /// or the last attempt failed; never before.
    private var tabStripVisible: Bool {
        Flags.uiPreview || summary.summaryExists || summary.status != .idle
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if tabStripVisible {
                // No hairline below: the strip reads as part of the document,
                // not separate chrome (user call, 2026-08-10). Regenerate
                // belongs to the AI Notes tab only.
                EditorTabStrip(
                    selected: $selectedTab,
                    showRegenerate: recorder.status == .idle && selectedTab == .aiNotes,
                    regenerateEnabled: summary.codexAvailable,
                    isWorking: summary.status == .working,
                    regenerateHelp: regenerateHelp,
                    onRegenerate: { summary.regenerate() })
            }
            if tabStripVisible && selectedTab == .aiNotes {
                aiNotesPane
            } else {
                MarkdownEditor(
                    text: $document.text, documentId: document.fileURL.path,
                    onLinkClick: handleLinkClick)
            }
            Divider()
            FilesSection(model: files)
        }
    }

    private var regenerateHelp: String {
        if summary.status == .working { return "Updating AI notes" }
        if !summary.codexAvailable {
            return "AI notes need the ChatGPT app. See the sidebar footer."
        }
        return "Update AI notes from the latest recording"
    }

    /// The AI Notes tab's states (spec §5): a failed banner with retry, the
    /// first-generation placeholder, or the summary editor — read-only
    /// while an update is in flight (`allowsHitTesting(false)` is the whole
    /// read-only mechanism: the completion write may replace the text, so
    /// typing must be off).
    @ViewBuilder private var aiNotesPane: some View {
        if case .failed = summary.status {
            // Try Again disappears while a recording runs (spec §3: no
            // trigger while recording); the banner itself stays so the
            // failure remains explained.
            StatusBanner(
                message: "AI notes couldn't be updated.",
                actionTitle: recorder.status == .idle ? "Try Again" : nil,
                action: recorder.status == .idle ? { summary.retry() } : nil
            )
        }
        if (summary.status == .working && !summary.summaryExists) || Flags.uiPreviewSummaryLoading {
            firstGenerationPlaceholder
        } else {
            MarkdownEditor(
                text: Flags.uiPreview && !summary.summaryExists
                    ? .constant(Self.previewSummary) : $aiDocument.text,
                documentId: aiDocument.fileURL.path,
                onLinkClick: handleLinkClick
            )
            .allowsHitTesting(summary.status != .working)
            .opacity(summary.status == .working ? 0.6 : 1)
        }
    }

    private var firstGenerationPlaceholder: some View {
        VStack(spacing: Design.rowGap) {
            Spacer()
            ProgressView()
            VStack(spacing: Design.innerGap) {
                Text("Writing your AI notes.")
                    .foregroundStyle(.secondary)
                Text("Simbi is reading the transcript and your notes to build a clean summary.")
                    .foregroundStyle(.tertiary)
            }
            .font(.body)
            .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Sample AI notes for `SIMBI_UI_PREVIEW=1` when no summary.md exists.
    private static let previewSummary = """
        # Weekly sync

        ## Launch
        - Launch slips to Friday; QA needs the extra days [[12:34]]
        - Sam owns the rollback plan [[18:02]]

        ## Action items
        - Dana files the status update today
        """

    /// Timestamp-shaped wiki-link targets seek and flash; anything else is
    /// reserved for future note links and ignored (AI Notes spec §6).
    private func handleLinkClick(_ target: String) {
        guard let seconds = TimestampLink.parse(target) else { return }
        if let entries = transcript.document?.entries,
            let row = TimestampLink.cueEntryIndex(for: seconds, in: entries)
        {
            transcriptFlash = CueFlash(row: row)
        }
        if recorder.status == .idle && playback.hasAudio {
            playback.play(from: seconds)
        }
    }

    /// In-app chat (SPEC.md §5.4): a note's chats live as native tabs of
    /// one window; reopening focuses it, new chats come from its + button.
    private var chatButton: some View {
        Button {
            ChatWindowManager.shared.openOrFocus(noteFolderURL: document.noteFolderURL)
        } label: {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
        }
        .help("Chat with Codex about this note")
    }

    /// §6 degraded states: recording works without Codex, but transcription
    /// and agent features need the ChatGPT app + a signed-in auth.json.
    private var degradedBanner: String? {
        if Flags.uiPreview {
            return "ChatGPT app not found. Transcription and Codex features are disabled."
        }
        if !CodexInstallation.standard.isBinaryInstalled {
            return "ChatGPT app not found. Transcription and Codex features are disabled."
        }
        if CodexInstallation.standard.loadAuth() == nil {
            return "Not signed in to ChatGPT. Transcription will queue on disk until you sign in."
        }
        return nil
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            if let degraded = degradedBanner {
                StatusBanner(message: degraded)
                Divider()
            }
            // System-audio-denied banner (previously inside RecordingHeader):
            // banners are banners — they all stack at the top of the pane.
            if let banner = systemAudioBanner {
                StatusBanner(
                    message: banner,
                    icon: "speaker.slash.fill",
                    actionTitle: "Open System Settings"
                ) {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
            }
            RecordingStatusStrip(recorder: recorder)
            // The player bar lives above the transcript whenever the note
            // has audio to play (hidden while recording — playing the note
            // back then would feed the speakers into the mic).
            if (recorder.status == .idle && playback.hasAudio) || Flags.uiPreview {
                PlaybackBar(playback: playback, noteFolderURL: document.noteFolderURL)
                Divider()
            }
            TranscriptView(
                model: transcript,
                playbackPosition: playback.isPlaying ? playback.position : nil,
                // Click a cue to play from it — same recording guard as
                // the player bar.
                onSeek: recorder.status == .idle && playback.hasAudio
                    ? { playback.play(from: $0) } : nil,
                onRenameSpeaker: { from, to in
                    try? SpeakerRename.renameInFile(
                        noteFolder: document.noteFolderURL, from: from, to: to)
                },
                flash: transcriptFlash
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The capture bar floats over the transcript (and over the
            // empty state — it's the pane's one always-present control).
            .bottomFloatingBar { RecordingBar(recorder: recorder) }
        }
        .background(.background.secondary)
    }

    /// Preview pins the denied state so the banner can be screenshotted.
    private var systemAudioBanner: String? {
        Flags.uiPreview
            ? "System audio capture was denied. Recording the mic only."
            : recorder.systemAudioBanner
    }
}

/// Player bar: play/pause, scrubber, position/duration readout. Shown
/// whenever the note has audio and isn't recording (SPEC.md §6).
struct PlaybackBar: View {
    let playback: PlaybackController
    let noteFolderURL: URL
    /// Non-nil while the user drags the scrubber; committed on release.
    @State private var scrubPosition: TimeInterval?
    /// True for a beat after a successful copy (checkmark feedback).
    @State private var copiedTranscript = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(HoverCircleButtonStyle())
            .help(playback.isPlaying ? "Pause" : "Play")
            Text(Design.time(scrubPosition ?? playback.position))
                .font(.metaMono)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { scrubPosition ?? min(playback.position, playback.duration) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(playback.duration, 0.01)
            ) { editing in
                if !editing, let target = scrubPosition {
                    playback.seek(to: target)
                    scrubPosition = nil
                }
            }
            .controlSize(.small)
            Text(Design.time(playback.duration))
                .font(.metaMono)
                .foregroundStyle(.tertiary)
            Button {
                copyTranscript()
            } label: {
                Image(systemName: copiedTranscript ? "checkmark" : "doc.on.doc")
                    .frame(width: 14)
            }
            .buttonStyle(HoverCircleButtonStyle())
            .help("Copy transcript")
            .disabled(!FileManager.default.fileExists(atPath: transcriptURL.path))
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, Design.stripPadding)
        .onAppear { playback.refreshDuration() }
    }

    private var transcriptURL: URL {
        noteFolderURL.appending(path: "transcript.vtt")
    }

    /// Reads transcript.vtt from disk at click time (the file is the
    /// source of truth, so this includes any fixer edits).
    private func copyTranscript() {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedTranscript = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedTranscript = false
        }
    }
}

/// Zero-size background view that fires `onClick` when the window's
/// toolbar title view is clicked. AppKit-level because SwiftUI offers no
/// working affordance here on macOS: the binding form of navigationTitle
/// renders a plain label, and `.toolbar(removing: .title)` plus a custom
/// title item collapses the toolbar's flexible region so the trailing
/// action buttons slide against the title. The recognizer lives on the
/// window's private `NSToolbarTitleView`; lookup is by class name only
/// and fails soft (no title view found → no click affordance).
private struct ToolbarTitleClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    @MainActor
    final class Coordinator: NSObject {
        var onClick: () -> Void = {}
        private weak var recognizer: NSClickGestureRecognizer?
        private weak var titleView: NSView?

        @objc private func clicked(_ sender: Any?) {
            // Only the title text counts, not the toolbar's whole flexible
            // region. Fail-soft: with no text field found (AppKit internals
            // moved), fire anywhere — rename must stay reachable.
            if let recognizer = sender as? NSClickGestureRecognizer,
                let titleView,
                let text = Self.findTextField(in: titleView),
                let textSuperview = text.superview
            {
                let point = recognizer.location(in: titleView)
                let textFrame = titleView.convert(text.frame, from: textSuperview)
                guard textFrame.contains(point) else { return }
            }
            onClick()
        }

        /// Idempotent: re-resolves the title view only when the current
        /// recognizer's host left the window (e.g. toolbar rebuilt).
        func install(in window: NSWindow?) {
            if let titleView, titleView.window != nil, recognizer != nil { return }
            guard let root = window?.contentView?.superview,
                let title = Self.findToolbarTitleView(in: root)
            else { return }
            // Sweep recognizers a previous NoteView left behind — SwiftUI
            // does not dismantle representables when an ancestor `.id`
            // changes (as every rename does), and the orphaned recognizer
            // (its target zeroed) sits first in line and eats the click.
            for existing in title.gestureRecognizers {
                if let click = existing as? NSClickGestureRecognizer,
                    click.target == nil || click.target is Coordinator
                {
                    title.removeGestureRecognizer(click)
                }
            }
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
            title.addGestureRecognizer(click)
            recognizer = click
            titleView = title
        }

        func uninstall() {
            if let recognizer, let titleView {
                titleView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            titleView = nil
        }

        private static func findToolbarTitleView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "NSToolbarTitleView" { return view }
            for subview in view.subviews {
                if let found = findToolbarTitleView(in: subview) { return found }
            }
            return nil
        }

        private static func findTextField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            for subview in view.subviews {
                if let found = findTextField(in: subview) { return found }
            }
            return nil
        }
    }

    /// Installs on `viewDidMoveToWindow` — the one deterministic moment
    /// the view has its window. A deferred install from updateNSView is
    /// not enough: after a rename recreates NoteView, the single update
    /// runs before the window is attached and never fires again.
    private final class AttachAwareView: NSView {
        var onAttach: (NSWindow) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onAttach(window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = AttachAwareView()
        view.onAttach = { [coordinator = context.coordinator] window in
            coordinator.install(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClick = onClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }
}
