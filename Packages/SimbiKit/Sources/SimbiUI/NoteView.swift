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
            MarkdownEditor(text: $document.text)
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
                Label(degraded, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12))
                Divider()
            }
            RecordingHeader(recorder: recorder)
            Divider()
            if playback.isPlaying {
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
        HStack(spacing: 8) {
            Button {
                playback.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop playback")
            Text(VTT.timestamp(playback.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Record/Stop button with live elapsed time and the tentative speaker
/// indicator.
struct RecordingHeader: View {
    @Bindable var recorder: RecordingController

    var body: some View {
        VStack(spacing: 6) {
            controls
            if let banner = recorder.systemAudioBanner {
                systemAudioBanner(banner)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: { recorder.toggle() }) {
                switch recorder.status {
                case .idle, .failed:
                    Label(
                        recorder.hasRecording ? "Resume" : "Record",
                        systemImage: "record.circle")
                case .preparing:
                    Label("Preparing…", systemImage: "hourglass")
                case .recording:
                    Label("Stop", systemImage: "stop.circle.fill")
                case .stopping:
                    Label("Stopping…", systemImage: "hourglass")
                }
            }
            .tint(recorder.status == .recording ? .red : nil)
            .disabled(recorder.status == .preparing || recorder.status == .stopping)

            Text(elapsedText)
                .font(.body.monospacedDigit())
                .foregroundStyle(recorder.status == .recording ? .primary : .secondary)

            // Source toggle (SPEC.md §3.1: mic / mic+system). Locked while
            // recording — the mix can't change mid-session.
            Toggle(isOn: $recorder.systemAudioEnabled) {
                Image(systemName: "speaker.wave.2")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(recorder.status != .idle)
            .help(
                recorder.systemAudioEnabled
                    ? "System audio is captured too (mic + system)"
                    : "Mic only — click to also capture system audio")

            Spacer()

            if recorder.status == .recording {
                if let slot = recorder.tentativeSpeaker {
                    Label("Speaker \(slot + 1) speaking…", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(TranscriptView.speakerColors[slot % 4])
                } else {
                    Label("silence", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if case .failed(let message) = recorder.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    /// Mic-only degraded-state banner with the System Settings deep link
    /// (SPEC.md §7).
    private func systemAudioBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "speaker.slash")
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("Open System Settings") {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private var elapsedText: String {
        let total = Int(recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
