import AppKit
import SwiftUI

extension NSWindow {
    /// The shared recipe for Simbi's ancillary windows (chat, thread
    /// viewer, instruction/context editors, Codex status): the owning
    /// manager keeps the strong reference and prunes it in
    /// `windowWillClose`, so the window is never released on close — and
    /// never restored, because a restored window would resurrect a codex
    /// process or an editor nobody asked for.
    func applyManagedStyle(
        tabbing: NSWindow.TabbingMode = .disallowed, minContentSize: NSSize? = nil
    ) {
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = tabbing
        if let minContentSize {
            contentMinSize = minContentSize
        }
        center()
    }
}

/// The markdown-editor window shared by the agent-instructions and
/// context editors: a hosted SwiftUI editor over one `AutosavingDocument`,
/// saved on close before the owner prunes its reference.
final class AutosaveEditorWindow: NSWindow, NSWindowDelegate {
    let document: AutosavingDocument
    private let onWillClose: (AutosaveEditorWindow) -> Void

    init(
        title: String, document: AutosavingDocument, content: some View,
        onWillClose: @escaping (AutosaveEditorWindow) -> Void
    ) {
        self.document = document
        self.onWillClose = onWillClose
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        self.title = title
        delegate = self
        contentView = NSHostingView(rootView: content)
        applyManagedStyle(minContentSize: NSSize(width: 440, height: 320))
    }

    func windowWillClose(_ notification: Notification) {
        document.saveNow()
        onWillClose(self)
    }
}
