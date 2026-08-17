import AppKit
import Observation
import SimbiKit
import SwiftUI

/// Owns the agent-instructions editor windows (one per file, focused on
/// reopen) and the Settings actions on the files themselves. Plain AppKit
/// windows like the chat windows: no scene persistence, no restoration.
@MainActor
public final class InstructionsEditorWindowManager {
    public static let shared = InstructionsEditorWindowManager()

    private var windows: [AgentInstructions: InstructionsEditorWindow] = [:]

    private var homeRootURL: URL { SimbiHome().rootURL }

    /// Settings' "Edit Instructions": focus the file's window or open one.
    public func open(_ file: AgentInstructions) {
        if let window = windows[file] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        materialize(file)
        // Starts from the file's effective contents (the built-in default
        // when the file is missing or blank).
        let window = InstructionsEditorWindow(
            file: file,
            document: AutosavingDocument(
                fileURL: file.url(homeRootURL: homeRootURL),
                initialText: file.contents(homeRootURL: homeRootURL)),
            manager: self)
        windows[file] = window
        window.makeKeyAndOrderFront(nil)
    }

    public func revealInFinder(_ file: AgentInstructions) {
        materialize(file)
        NSWorkspace.shared.activateFileViewerSelecting([file.url(homeRootURL: homeRootURL)])
    }

    /// Overwrites the file with the built-in default. An open editor
    /// window is updated in place so it can't autosave stale text back.
    public func reset(_ file: AgentInstructions) {
        if let window = windows[file] {
            window.document.text = file.defaultContents
            window.document.saveNow()
        } else {
            do {
                try file.defaultContents.write(
                    to: file.url(homeRootURL: homeRootURL), atomically: true, encoding: .utf8)
            } catch {
                Log.ui.error("resetting \(file.fileName) failed: \(error)")
            }
        }
    }

    /// Bootstrap normally creates the files, but a user may have deleted
    /// one (that's the documented reset gesture) — recreate before any
    /// action that needs a real file on disk.
    private func materialize(_ file: AgentInstructions) {
        let url = file.url(homeRootURL: homeRootURL)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try file.defaultContents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.ui.error("recreating \(file.fileName) failed: \(error)")
        }
    }

    fileprivate func windowWillClose(_ window: InstructionsEditorWindow) {
        windows.removeValue(forKey: window.file)
    }
}

/// One instruction file's editor: the note markdown editor as the whole
/// content view.
final class InstructionsEditorWindow: NSWindow, NSWindowDelegate {
    let file: AgentInstructions
    let document: AutosavingDocument
    private weak var manager: InstructionsEditorWindowManager?

    init(
        file: AgentInstructions, document: AutosavingDocument,
        manager: InstructionsEditorWindowManager
    ) {
        self.file = file
        self.document = document
        self.manager = manager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        title = "Instructions: \(file.fileName)"
        // The manager keeps the strong reference; never restore these —
        // same rules as the chat windows.
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .disallowed
        delegate = self
        contentMinSize = NSSize(width: 440, height: 320)
        contentView = NSHostingView(
            rootView: InstructionsEditorView(file: file, document: document))
        center()
    }

    func windowWillClose(_ notification: Notification) {
        document.saveNow()
        manager?.windowWillClose(self)
    }
}

private struct InstructionsEditorView: View {
    let file: AgentInstructions
    @Bindable var document: AutosavingDocument

    var body: some View {
        VStack(spacing: 0) {
            MarkdownEditor(
                text: $document.text,
                documentId: document.fileURL.path,
                flavor: .instructions
            )
            .onChange(of: document.text) {
                document.scheduleAutosave()
            }
            Divider()
            // The variable chips are syntax-only — this is what tells the
            // user which names the app actually fills for this file.
            HStack {
                Text(variablesHint)
                    .font(.meta)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Design.paneInset)
            .padding(.vertical, Design.stripPadding)
        }
    }

    private var variablesHint: String {
        let variables = file.variables
        guard !variables.isEmpty else {
            return "This file has no variables."
        }
        return "Available variables: "
            + variables.map { "{{ \($0) }}" }.joined(separator: ", ")
    }
}
