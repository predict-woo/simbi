import AppKit
import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit
import SplitViewKit
import SwiftUI

/// The note view: title, `note.md` editor, recording controls and the live
/// transcript pane (SPEC.md §6).
struct NoteView: View {
    let noteFolderURL: URL
    @State private var document: AutosavingDocument
    @State private var recorder: RecordingController
    @State private var transcript: TranscriptModel
    @State private var files: FilesModel
    @State private var playback: PlaybackController
    @State private var summary: SummaryController
    @State private var titleController: TitleController
    @State private var aiDocument: AutosavingDocument
    @State private var selectedTab: EditorTab = .myNotes
    @State private var transcriptFlash: CueFlash?
    @State private var renameDialogShown = false
    @State private var renameText = ""

    /// Renames the note folder — routed through FileTreeModel so the
    /// sidebar order and selection follow the folder to its new URL.
    let renameNote: (String) -> Void

    init(noteFolderURL: URL, renameNote: @escaping (String) -> Void) {
        self.noteFolderURL = noteFolderURL
        self._document = State(
            initialValue: AutosavingDocument(
                fileURL: noteFolderURL.appending(path: FileTreeScanner.noteMarkerName)))
        self._recorder = State(initialValue: RecordingController.shared(noteFolderURL: noteFolderURL))
        self._transcript = State(initialValue: TranscriptModel(noteFolderURL: noteFolderURL))
        self._files = State(initialValue: FilesModel.shared(noteFolderURL: noteFolderURL))
        self._playback = State(initialValue: PlaybackController(noteFolderURL: noteFolderURL))
        self._summary = State(initialValue: SummaryController.shared(noteFolderURL: noteFolderURL))
        self._titleController = State(
            initialValue: TitleController.shared(noteFolderURL: noteFolderURL))
        self._aiDocument = State(
            initialValue: AutosavingDocument(
                fileURL: NoteLayout.summaryURL(noteFolder: noteFolderURL)))
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
        .navigationTitle(noteFolderURL.lastPathComponent)
        // Clicking the toolbar title opens the same rename dialog as the
        // sidebar's context menu. SwiftUI's binding navigationTitle is
        // documented to make the title editable but does nothing on macOS,
        // and replacing the title item wrecks the toolbar's flexible
        // layout — so an AppKit click hook on the title view it is.
        .background(
            ToolbarTitleClickCatcher {
                renameText = noteFolderURL.lastPathComponent
                renameDialogShown = true
            }
        )
        .renameAlert(isPresented: $renameDialogShown, name: $renameText) { name in
            renameNote(name)
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
                    NSWorkspace.shared.open(noteFolderURL)
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
            // All three controllers are app-lifetime singletons for this
            // note, so capturing them here stays valid across view
            // recreation; the auto-rename waits for both to finish.
            titleController.noteIsQuiet = { [recorder, summary] in
                TitleController.isQuiet(
                    fixerStatus: recorder.fixerActivity.status,
                    summaryWorking: summary.status == .working)
            }
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
            ChatWindowManager.shared.openOrFocus(noteFolderURL: noteFolderURL)
        } label: {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
        }
        .help("Chat with Codex about this note")
    }

    /// §6 degraded states: recording works without Codex, but transcription
    /// and agent features need the ChatGPT app + a signed-in auth.json.
    /// Observes the shared model, so the banner clears live on sign-in
    /// (and `SIMBI_UI_PREVIEW_CODEX` forces any state for screenshots).
    private var degradedBanner: String? {
        switch CodexSetupModel.shared.state {
        case .notInstalled:
            return "ChatGPT app not found. Transcription and Codex features are disabled."
        case .signedOut:
            return "Not signed in to ChatGPT. Transcription will queue on disk until you sign in."
        case .connected:
            return nil
        }
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
                PlaybackBar(playback: playback, noteFolderURL: noteFolderURL)
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
                    do {
                        try SpeakerRename.renameInFile(
                            noteFolder: noteFolderURL, from: from, to: to)
                    } catch {
                        Log.ui.error("renaming speaker \(from) to \(to) failed: \(error)")
                    }
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
