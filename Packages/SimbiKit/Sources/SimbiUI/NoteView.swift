import AppKit
import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit
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

    init(noteFolderURL: URL) {
        self._document = State(initialValue: NoteDocument(noteFolderURL: noteFolderURL))
        self._recorder = State(initialValue: RecordingController.shared(noteFolderURL: noteFolderURL))
        self._transcript = State(initialValue: TranscriptModel(noteFolderURL: noteFolderURL))
        self._files = State(initialValue: FilesModel.shared(noteFolderURL: noteFolderURL))
        self._playback = State(initialValue: PlaybackController(noteFolderURL: noteFolderURL))
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 320, idealWidth: 560)
            transcriptPane
                .frame(minWidth: 260, idealWidth: 380)
        }
        .navigationTitle(document.noteFolderURL.lastPathComponent)
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

    /// In-app chat (SPEC.md §5.4): one persistent Codex thread per note,
    /// one window per note; reopening focuses it.
    private var chatButton: some View {
        Button {
            openWindow(id: ChatWindow.windowId, value: document.noteFolderURL)
        } label: {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
        }
        .help("Chat with Codex about this note")
    }

    /// §6 degraded states: recording works without Codex, but transcription
    /// and agent features need the ChatGPT app + a signed-in auth.json.
    private var degradedBanner: String? {
        if Design.uiPreview {
            return "ChatGPT app not found — transcription and Codex features are disabled."
        }
        if !CodexInstallation.standard.isBinaryInstalled {
            return "ChatGPT app not found — transcription and Codex features are disabled."
        }
        if CodexInstallation.standard.loadAuth() == nil {
            return "Not signed in to ChatGPT — transcription will queue on disk until you sign in."
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
            .buttonStyle(.borderless)
            .help(playback.isPlaying ? "Pause" : "Play")
            Text(Design.time(scrubPosition ?? playback.position))
                .font(.meta.monospacedDigit())
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
                .font(.meta.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, 8)
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
                .padding(.vertical, 10)
            let banner =
                Design.uiPreview
                ? "System audio capture was denied — recording the mic only." : recorder.systemAudioBanner
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
                                .foregroundStyle(.red)
                        }
                    case .preparing:
                        Label("Preparing…", systemImage: "record.circle")
                    case .recording, .stopping:
                        Label("Stopping…", systemImage: "stop.circle")
                    }
                }
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .red : nil)
            .disabled(recorder.status == .preparing || recorder.status == .stopping)

            HStack(spacing: 6) {
                if isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
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
                    .foregroundStyle(.red)
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
                        ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .modifier(PulseEffect(active: recorder.fixerActivity.status == .working))
        }
        .buttonStyle(.borderless)
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
        .buttonStyle(.borderless)
        .help("Pipeline Inspector — watch the recording pipeline work")
    }

    private var fixerHelp: String {
        switch recorder.fixerActivity.status {
        case .off: "Transcript fixer"
        case .waiting: "Transcript fixer — waiting for new cues"
        case .working: "Transcript fixer — reviewing"
        case .done: "Transcript fixer — done"
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
                    !mics.contains(where: { $0.id == uid }) {
                    micOption("Saved microphone (not connected)", selected: true) {}
                }
            }
            Section("System audio") {
                Toggle("Capture system audio", isOn: $recorder.systemAudioEnabled)
                    // Same guard from the other side: last source stays on.
                    .disabled(!recorder.micEnabled)
            }
        } label: {
            HStack(spacing: 5) {
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
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.meta)
                SpeakerChip(name: name)
            }
            .foregroundStyle(Design.speakerColor(name))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Design.speakerColor(name).opacity(0.12), in: Capsule())
        } else {
            Text("Listening…")
                .font(.meta)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Slow opacity pulse for the live recording dot.
private struct PulseEffect: ViewModifier {
    var active = true
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.3 : 1)
            .animation(
                active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: dimmed
            )
            .onAppear { dimmed = active }
            .onChange(of: active) { _, nowActive in
                dimmed = nowActive
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
                            ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .modifier(PulseEffect(active: model.status == .working))
                Text(headline(model.status))
                    .font(.headline)
                Spacer()
            }
            if model.events.isEmpty {
                Text("No activity yet — the fixer reviews cues as they arrive.")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: event.icon)
                                    .font(.meta)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(event.text)
                                    .font(.meta)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text(event.date, style: .time)
                                    .font(.meta)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320, idealWidth: 380, minHeight: 180, idealHeight: 300)
        .navigationTitle("Fixer — \(noteName)")
    }

    private func headline(_ status: FixerActivityModel.Status) -> String {
        switch status {
        case .off: "Transcript Fixer"
        case .waiting: "Waiting for new cues"
        case .working: "Reviewing…"
        case .done: "Done — all cues reviewed"
        }
    }
}
