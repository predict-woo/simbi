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

/// The note view: title, `note.md` editor, and (until M2) a placeholder
/// where the recording controls and live transcript pane will live.
struct NoteView: View {
    @State private var document: NoteDocument

    init(noteFolderURL: URL) {
        self._document = State(initialValue: NoteDocument(noteFolderURL: noteFolderURL))
    }

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 320, idealWidth: 560)
            transcriptPane
                .frame(minWidth: 240, idealWidth: 360)
        }
        .navigationTitle(document.noteFolderURL.lastPathComponent)
        .onChange(of: document.text) {
            document.scheduleAutosave()
        }
        .onDisappear {
            document.saveNow()
        }
    }

    private var editorPane: some View {
        MarkdownEditor(text: $document.text)
    }

    private var transcriptPane: some View {
        ContentUnavailableView(
            "No Recording",
            systemImage: "waveform",
            description: Text("Recording and the live transcript arrive in M2.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }
}
