import AppKit
import Observation
import SwiftUI

/// Owns the context editor windows (one per context file, focused on
/// reopen). Plain AppKit windows like the instructions editors: no scene
/// persistence, no restoration.
@MainActor
public final class ContextEditorWindowManager {
    public static let shared = ContextEditorWindowManager()

    private var windows: [String: AutosaveEditorWindow] = [:]

    /// The files view's "Open Context": focus the file's window or open one.
    func open(fileURL: URL, title: String) {
        if let window = windows[fileURL.path] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let document = AutosavingDocument(fileURL: fileURL)
        let window = AutosaveEditorWindow(
            title: title,
            document: document,
            content: ContextEditorView(document: document),
            onWillClose: { [weak self] _ in self?.windows.removeValue(forKey: fileURL.path) })
        windows[fileURL.path] = window
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ContextEditorView: View {
    @Bindable var document: AutosavingDocument

    var body: some View {
        VStack(spacing: 0) {
            if document.hasConflict {
                FileConflictBanner(document: document)
            }
            MarkdownEditor(
                text: $document.text,
                documentId: document.fileURL.path,
                flavor: .note
            )
            .onChange(of: document.text) {
                document.scheduleAutosave()
            }
        }
    }
}
