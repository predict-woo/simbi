import AppKit
import CodexKit
import Foundation
import Observation
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

    @State private var chatStatus: ChatStatus = .idle

    private enum ChatStatus: Equatable {
        case idle
        case starting
        case failed
    }

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

    /// "Chat in Codex" (SPEC.md §5.4): thread at the home root, context
    /// turn, then focus the ChatGPT app on it.
    private var chatButton: some View {
        Button {
            chatStatus = .starting
            Task {
                do {
                    let settings =
                        (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
                    let threadId = try await CodexChat.startChat(
                        noteFolderURL: document.noteFolderURL,
                        homeRootURL: SimbiHome().rootURL,
                        client: CodexServices.appServer,
                        model: settings.chatModel)
                    if let url = URL(string: "codex://threads/\(threadId)") {
                        NSWorkspace.shared.open(url)
                    }
                    chatStatus = .idle
                } catch {
                    chatStatus = .failed
                }
            }
        } label: {
            if chatStatus == .starting {
                Label("Starting…", systemImage: "hourglass")
            } else {
                Label("Chat in Codex", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .disabled(chatStatus == .starting)
        .help(
            chatStatus == .failed
                ? "Could not start the chat thread — is the ChatGPT app installed?"
                : "Discuss this note in the ChatGPT app")
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
            if playback.isPlaying || Design.uiPreview {
                PlaybackBar(playback: playback)
                Divider()
            }
            TranscriptView(
                model: transcript,
                // Playing the note back while recording would feed the
                // speakers into the mic — seek only when idle.
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

/// Position readout + stop control, shown only while playing (SPEC.md §6).
struct PlaybackBar: View {
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop playback")
            Image(systemName: "speaker.wave.2.fill")
                .font(.meta)
                .foregroundStyle(.tint)
            Text(Design.time(playback.position))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, 8)
    }
}

/// Record/Stop button with live elapsed time and the tentative speaker
/// indicator. Reads like a recorder: red affordance, pulsing dot while
/// live, monospaced timer.
struct RecordingHeader: View {
    @Bindable var recorder: RecordingController

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
            Button(action: { recorder.toggle() }) {
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

            // Source toggle (SPEC.md §3.1: mic / mic+system). Locked while
            // recording — the mix can't change mid-session. Quiet icon: the
            // symbol carries the state so it doesn't compete with Record.
            Button {
                recorder.systemAudioEnabled.toggle()
            } label: {
                Image(systemName: recorder.systemAudioEnabled ? "speaker.wave.2" : "speaker.slash")
                    .foregroundStyle(
                        recorder.systemAudioEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .disabled(recorder.status != .idle)
            .help(
                recorder.systemAudioEnabled
                    ? "System audio is captured too (mic + system)"
                    : "Mic only — click to also capture system audio")
        }
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
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}
