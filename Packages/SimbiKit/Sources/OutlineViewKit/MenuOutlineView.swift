import Cocoa
import SwiftUI

// Local addition to the vendored package (see VENDORED.md): per-row context
// menus, which upstream OutlineView does not support.

/// `NSOutlineView` subclass that vends a context menu for the clicked row
/// (or for the empty area below the rows, passing `nil`).
final class MenuOutlineView: NSOutlineView {
    var menuProvider: ((Any?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menuProvider else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        return menuProvider(row >= 0 ? item(atRow: row) : nil)
    }
}

@available(macOS 10.15, *)
extension OutlineViewController {
    func setContextMenuProvider(_ provider: ((Data.Element?) -> NSMenu?)?) {
        guard let menuOutlineView = outlineView as? MenuOutlineView else { return }
        guard let provider else {
            menuOutlineView.menuProvider = nil
            return
        }
        menuOutlineView.menuProvider = { anyItem in
            provider((anyItem as? OutlineViewItem<Data>)?.value)
        }
    }
}

@available(macOS 10.15, *)
public extension OutlineView {
    /// Sets a provider for per-row context menus. The provider receives the
    /// clicked element, or `nil` for a click in the empty area of the view.
    func contextMenu(_ provider: @escaping (Data.Element?) -> NSMenu?) -> Self {
        var mutableSelf = self
        mutableSelf.contextMenuProvider = provider
        return mutableSelf
    }

    /// Draws row selection un-emphasized (the system's adaptive gray,
    /// `unemphasizedSelectedContentBackgroundColor`) instead of the accent
    /// color, in both light and dark appearance.
    func quietRowSelection() -> Self {
        var mutableSelf = self
        mutableSelf.quietRowSelectionEnabled = true
        return mutableSelf
    }
}

/// Row view whose selection always draws in the unemphasized (gray) style,
/// regardless of first-responder status.
@available(macOS 11.0, *)
final class QuietSelectionRowView: AdjustableSeparatorRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

@available(macOS 10.15, *)
extension OutlineViewController {
    func setQuietRowSelection(_ enabled: Bool) {
        delegate.quietRowSelection = enabled
    }
}
