import AppKit
import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit
import SplitViewKit
import SwiftUI

/// Loads and autosaves a note folder's `note.md`.
@MainActor
@Observable
final class NoteDocument {
    let noteFolderURL: URL
    var text: String

    private var saveTask: Task<Void, Never>?

    var fileURL: URL {
        noteFolderURL.appending(path: FileTreeScanner.noteMarkerName)
    }

    init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let fileURL = noteFolderURL.appending(path: FileTreeScanner.noteMarkerName)
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
        self.renameNote = renameNote
    }

    @Environment(\.openWindow) private var openWindow

    /// Pane floors in points (converted to fractions for SplitViewKit) and
    /// the initial divider position, matching the old 560/380 ideal split.
    private static let editorMinWidth: CGFloat = 260
    private static let transcriptMinWidth: CGFloat = 220
    private static let initialEditorFraction: CGFloat = 0.6

    /// The divider position. Must be @State: SplitViewKit resets its
    /// internal fraction whenever the holder's value changes between
    /// renders, so a holder rebuilt in `body` would snap a dragged
    /// divider back to the initial fraction on every window resize.
    @State private var splitFraction = FractionHolder(NoteView.initialEditorFraction)

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
                .fraction(splitFraction)
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
        }
        .onChange(of: document.text) {
            document.scheduleAutosave()
        }
        // Starting a recording silences playback (speakers → mic feedback).
        .onChange(of: recorder.status) { _, status in
            if status != .idle {
                playback.pause()
            }
        }
        // Recording deliberately continues if the view goes away (the
        // controller is shared per note); only the Stop button ends it.
        // Playback is view-local and does stop.
        .onDisappear {
            document.saveNow()
            playback.stop()
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            MarkdownEditor(text: $document.text, documentId: document.fileURL.path)
            Divider()
            FilesSection(model: files)
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
        if Design.uiPreview {
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
            RecordingHeader(recorder: recorder)
            Divider()
            // The player bar lives above the transcript whenever the note
            // has audio to play (hidden while recording — playing the note
            // back then would feed the speakers into the mic).
            if (recorder.status == .idle && playback.hasAudio) || Design.uiPreview {
                PlaybackBar(playback: playback)
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
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background.secondary)
    }
}

/// Player bar: play/pause, scrubber, position/duration readout. Shown
/// whenever the note has audio and isn't recording (SPEC.md §6).
struct PlaybackBar: View {
    let playback: PlaybackController
    /// Non-nil while the user drags the scrubber; committed on release.
    @State private var scrubPosition: TimeInterval?

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
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, Design.stripPadding)
        .onAppear { playback.refreshDuration() }
    }
}

/// Record/Stop button with live elapsed time and the tentative speaker
/// indicator. Reads like a recorder: red affordance, pulsing dot while
/// live, monospaced timer.
struct RecordingHeader: View {
    @Bindable var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    private var isRecording: Bool { recorder.status == .recording || Design.uiPreview }

    /// Live-speaker slot; the preview flag pins one so the chip is visible.
    private var tentativeSpeaker: Int? {
        Design.uiPreview ? 1 : recorder.tentativeSpeaker
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, Design.paneInset)
                .padding(.vertical, Design.stripPadding)
            let banner =
                Design.uiPreview
                ? "System audio capture was denied. Recording the mic only." : recorder.systemAudioBanner
            if let banner {
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
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            // Idle: neutral button, red dot icon (ready). Recording: filled
            // red Stop — red means "live", not "will be live".
            Button {
                recorder.toggle()
            } label: {
                if isRecording {
                    Label("Stop", systemImage: "stop.fill")
                } else {
                    switch recorder.status {
                    case .idle, .failed:
                        Label {
                            Text(recorder.hasRecording ? "Resume" : "Record")
                        } icon: {
                            Image(systemName: "record.circle.fill")
                                .foregroundStyle(Color.statusLive)
                        }
                    case .preparing:
                        Label("Preparing…", systemImage: "record.circle")
                    case .recording, .stopping:
                        Label("Stopping…", systemImage: "stop.circle")
                    }
                }
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .statusLive : nil)
            .disabled(recorder.status == .preparing || recorder.status == .stopping)

            HStack(spacing: Design.iconGap) {
                if isRecording {
                    StatusDot(color: .statusLive)
                        .modifier(PulseEffect())
                }
                Text(Design.time(recorder.elapsed))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(isRecording ? .primary : .secondary)
            }

            Spacer()

            if isRecording {
                liveIndicator
            }
            if case .failed(let message) = recorder.status {
                Text(message)
                    .font(.meta)
                    .foregroundStyle(Color.statusLive)
                    .lineLimit(2)
            }

            // Fixer status/activity (SPEC.md §5.2): sparkles pulse while a
            // pass runs; the popover shows the coarse one-line feed. Hidden
            // until a fixer has ever existed for this note.
            if recorder.fixerActivity.status != .off || Design.uiPreview {
                fixerButton
            }

            // Pipeline Inspector: live view of the recording pipeline's
            // internals. Only meaningful mid-session, so recording-only.
            if isRecording {
                inspectorButton
            }

            // Source menu (SPEC.md §3.1: mic device and system audio are
            // chosen independently; either can be off, never both). Locked
            // while recording — the mix can't change mid-session. Quiet
            // icons: the symbols carry the state so they don't compete
            // with Record.
            sourcesMenu
        }
    }

    private var fixerButton: some View {
        Button {
            // One activity window per note; reopening focuses it.
            openWindow(id: FixerActivityWindow.windowId, value: recorder.noteFolderURL)
        } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(
                    recorder.fixerActivity.status == .working
                        ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                )
                .modifier(PulseEffect(active: recorder.fixerActivity.status == .working))
        }
        .buttonStyle(HoverCircleButtonStyle())
        .help(fixerHelp)
    }

    private var inspectorButton: some View {
        Button {
            // One inspector window per note; reopening focuses it.
            openWindow(id: PipelineInspectorWindow.windowId, value: recorder.noteFolderURL)
        } label: {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(HoverCircleButtonStyle())
        .help("Pipeline Inspector: watch the recording pipeline work")
    }

    private var fixerHelp: String {
        switch recorder.fixerActivity.status {
        case .off: "Transcript fixer"
        case .waiting: "Transcript fixer: waiting for new cues"
        case .working: "Transcript fixer: reviewing"
        case .done: "Transcript fixer: done"
        }
    }

    private var sourcesMenu: some View {
        Menu {
            Section("Microphone") {
                micOption("Off", selected: !recorder.micEnabled) {
                    recorder.micEnabled = false
                }
                // Turning the mic off with system audio off would leave
                // nothing to record.
                .disabled(!recorder.systemAudioEnabled)
                micOption(
                    "System default",
                    selected: recorder.micEnabled && recorder.micDeviceUID == nil
                ) {
                    recorder.micEnabled = true
                    recorder.micDeviceUID = nil
                }
                let mics = recorder.availableMicrophones
                ForEach(mics) { mic in
                    micOption(
                        mic.name,
                        selected: recorder.micEnabled && recorder.micDeviceUID == mic.id
                    ) {
                        recorder.micEnabled = true
                        recorder.micDeviceUID = mic.id
                    }
                }
                // Keep a saved-but-unplugged mic visible so the selection
                // isn't silently misrepresented.
                if recorder.micEnabled, let uid = recorder.micDeviceUID,
                    !mics.contains(where: { $0.id == uid })
                {
                    micOption("Saved microphone (not connected)", selected: true) {}
                }
            }
            Section("System audio") {
                Toggle("Capture system audio", isOn: $recorder.systemAudioEnabled)
                    // Same guard from the other side: last source stays on.
                    .disabled(!recorder.micEnabled)
            }
        } label: {
            HStack(spacing: Design.iconGap) {
                Image(systemName: recorder.micEnabled ? "mic.fill" : "mic.slash")
                    .foregroundStyle(
                        recorder.micEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Image(
                    systemName: recorder.systemAudioEnabled ? "speaker.wave.2" : "speaker.slash"
                )
                .foregroundStyle(
                    recorder.systemAudioEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(Design.footerStripPadding)
        .hoverFill(Capsule())
        .disabled(recorder.status != .idle)
        .help(sourcesSummary)
    }

    private func micOption(
        _ title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        // Toggle rows get the native menu checkmark on the active option.
        Toggle(title, isOn: .init(get: { selected }, set: { _ in action() }))
    }

    /// Tooltip summary, e.g. "Recording: MacBook Pro Microphone + system audio".
    private var sourcesSummary: String {
        var parts: [String] = []
        if recorder.micEnabled {
            let name =
                recorder.availableMicrophones
                .first { $0.id == recorder.micDeviceUID }?.name
            parts.append(name ?? "default microphone")
        }
        if recorder.systemAudioEnabled {
            parts.append("system audio")
        }
        return "Recording: " + parts.joined(separator: " + ")
    }

    /// Who the diarizer currently hears, in the same chip language as the
    /// transcript rows — header and transcript read as one system.
    @ViewBuilder
    private var liveIndicator: some View {
        if let slot = tentativeSpeaker {
            let name = "Speaker \(slot + 1)"
            HStack(spacing: Design.iconGap) {
                Image(systemName: "waveform")
                    .font(.meta)
                SpeakerChip(name: name)
            }
            .foregroundStyle(Design.speakerColor(name))
            .padding(.horizontal, 8)
            .padding(.vertical, Design.innerGap)
            .background(Design.speakerTint(name), in: Capsule())
        } else {
            Text("Listening…")
                .font(.meta)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The per-note fixer activity window (SPEC.md §5.2): coarse status
/// headline over the one-line event feed. A glance at what the fixer is
/// doing, not a log. The app shell declares the matching
/// `WindowGroup(id: windowId, for: URL.self)` scene.
public struct FixerActivityWindow: View {
    public static let windowId = "fixer-activity"

    private let recorder: RecordingController
    private let noteName: String

    public init(noteFolderURL: URL) {
        self.recorder = RecordingController.shared(noteFolderURL: noteFolderURL)
        self.noteName = noteFolderURL.lastPathComponent
    }

    public var body: some View {
        let model = recorder.fixerActivity
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(
                        model.status == .working
                            ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                    )
                    .modifier(PulseEffect(active: model.status == .working))
                Text(headline(model.status))
                    .font(.headline)
                Spacer()
            }
            Spacer()
        }
        .padding(12)
        .frame(minWidth: 320, idealWidth: 380, minHeight: 180, idealHeight: 300)
        .navigationTitle("Fixer: \(noteName)")
    }

    private func headline(_ status: FixerActivityModel.Status) -> String {
        switch status {
        case .off: "Transcript Fixer"
        case .waiting: "Waiting for new cues"
        case .working: "Reviewing…"
        case .done: "Done: all cues reviewed"
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
