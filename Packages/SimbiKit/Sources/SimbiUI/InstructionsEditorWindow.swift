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

    private var windows: [AgentInstructions: AutosaveEditorWindow] = [:]

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
        let document = AutosavingDocument(
            fileURL: file.url(homeRootURL: homeRootURL),
            initialText: file.contents(homeRootURL: homeRootURL))
        let window = AutosaveEditorWindow(
            title: "Instructions: \(file.fileName)",
            document: document,
            content: InstructionsEditorView(file: file, document: document),
            onWillClose: { [weak self] _ in self?.windows.removeValue(forKey: file) })
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

}

private struct InstructionsEditorView: View {
    let file: AgentInstructions
    @Bindable var document: AutosavingDocument

    var body: some View {
        VStack(spacing: 0) {
            if document.hasConflict {
                FileConflictBanner(document: document)
            }
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
