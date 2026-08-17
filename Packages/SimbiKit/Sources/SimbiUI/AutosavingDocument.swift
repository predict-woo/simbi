import Foundation
import Observation
import SimbiKit

/// Loads and autosaves one text file: debounced saves while editing, an
/// explicit `saveNow()` on the closing paths. The one document class
/// behind the note editor, the AI-notes editor, the agent-instructions
/// editors, and the context editors.
@MainActor
@Observable
final class AutosavingDocument {
    let fileURL: URL
    var text: String

    private var saveTask: Task<Void, Never>?

    /// `initialText` overrides the plain file read — the instructions
    /// editor starts from the built-in default when its file is missing
    /// or blank.
    init(fileURL: URL, initialText: String? = nil) {
        self.fileURL = fileURL
        self.text = initialText ?? ((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
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

    /// Never materializes a missing file for empty content: summary.md's
    /// mere existence is state (it makes the tab strip appear), so a note
    /// that never had AI notes must not gain an empty file.
    func saveNow() {
        if text.isEmpty && !FileManager.default.fileExists(atPath: fileURL.path) { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.files.error("autosaving \(fileURL.lastPathComponent) failed: \(error)")
        }
    }
}
