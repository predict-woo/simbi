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

    init(noteFolderURL: URL) {
        self._document = State(initialValue: NoteDocument(noteFolderURL: noteFolderURL))
        self._recorder = State(initialValue: RecordingController.shared(noteFolderURL: noteFolderURL))
        self._transcript = State(initialValue: TranscriptModel(noteFolderURL: noteFolderURL))
        self._files = State(initialValue: FilesModel.shared(noteFolderURL: noteFolderURL))
    }

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 320, idealWidth: 560)
            transcriptPane
                .frame(minWidth: 260, idealWidth: 380)
        }
        .navigationTitle(document.noteFolderURL.lastPathComponent)
        .onChange(of: document.text) {
            document.scheduleAutosave()
        }
        // Recording deliberately continues if the view goes away (the
        // controller is shared per note); only the Stop button ends it.
        .onDisappear {
            document.saveNow()
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            MarkdownEditor(text: $document.text)
            Divider()
            FilesSection(model: files)
        }
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            RecordingHeader(recorder: recorder)
            Divider()
            TranscriptView(model: transcript)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background.secondary)
    }
}

/// Record/Stop button with live elapsed time and the tentative speaker
/// indicator.
struct RecordingHeader: View {
    let recorder: RecordingController

    var body: some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var elapsedText: String {
        let total = Int(recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
