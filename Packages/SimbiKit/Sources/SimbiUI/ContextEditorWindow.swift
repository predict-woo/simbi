import AppKit
import Observation
import SwiftUI

/// Owns the context editor windows (one per context file, focused on
/// reopen). Plain AppKit windows like the instructions editors: no scene
/// persistence, no restoration.
@MainActor
public final class ContextEditorWindowManager {
    public static let shared = ContextEditorWindowManager()

    private var windows: [String: ContextEditorWindow] = [:]

    /// The files view's "Open Context": focus the file's window or open one.
    func open(fileURL: URL, title: String) {
        if let window = windows[fileURL.path] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = ContextEditorWindow(
            document: AutosavingDocument(fileURL: fileURL), title: title, manager: self)
        windows[fileURL.path] = window
        window.makeKeyAndOrderFront(nil)
    }

    fileprivate func windowWillClose(_ window: ContextEditorWindow) {
        windows.removeValue(forKey: window.document.fileURL.path)
    }
}

/// One context file's editor: the note markdown editor as the whole
/// content view.
final class ContextEditorWindow: NSWindow, NSWindowDelegate {
    let document: AutosavingDocument
    private weak var manager: ContextEditorWindowManager?

    init(document: AutosavingDocument, title: String, manager: ContextEditorWindowManager) {
        self.document = document
        self.manager = manager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        self.title = title
        // The manager keeps the strong reference; never restore these —
        // same rules as the chat windows.
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .disallowed
        delegate = self
        contentMinSize = NSSize(width: 440, height: 320)
        contentView = NSHostingView(rootView: ContextEditorView(document: document))
        center()
    }

    func windowWillClose(_ notification: Notification) {
        document.saveNow()
        manager?.windowWillClose(self)
    }
}

private struct ContextEditorView: View {
    @Bindable var document: AutosavingDocument

    var body: some View {
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
