import Cocoa
import SwiftUI

// Local addition to the vendored package (see VENDORED.md): per-row context
// menus, which upstream OutlineView does not support.

/// `NSOutlineView` subclass that vends a context menu for the clicked row
/// (or for the empty area below the rows, passing `nil`).
final class MenuOutlineView: NSOutlineView {
    var menuProvider: ((Any?) -> NSMenu?)?

    /// When set, a click on a row the delegate refuses to select
    /// (`outlineView(_:shouldSelectItem:)`) toggles the row's expansion
    /// instead. Disclosure-triangle clicks never reach the click action,
    /// so they keep their native single toggle.
    var togglesUnselectableRowsOnClick = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(handleClick)
    }

    required init?(coder: NSCoder) { nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menuProvider else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        return menuProvider(row >= 0 ? item(atRow: row) : nil)
    }

    @objc private func handleClick(_ sender: Any?) {
        guard togglesUnselectableRowsOnClick,
            NSApp.currentEvent.map({ $0.clickCount <= 1 }) ?? true,
            clickedRow >= 0,
            let item = item(atRow: clickedRow),
            delegate?.outlineView?(self, shouldSelectItem: item) == false,
            isExpandable(item)
        else { return }
        if isItemExpanded(item) {
            animator().collapseItem(item)
        } else {
            animator().expandItem(item)
        }
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

    /// Restricts selection to elements passing `predicate`. A click on a
    /// row that fails the predicate toggles its expansion (when it has
    /// children) instead of selecting it; keyboard selection skips it.
    func selectableRows(_ predicate: @escaping (Data.Element) -> Bool) -> Self {
        var mutableSelf = self
        mutableSelf.selectionFilter = predicate
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

    func setSelectionFilter(_ filter: ((Data.Element) -> Bool)?) {
        delegate.selectionFilter = filter
        outlineView.togglesUnselectableRowsOnClick = filter != nil
    }
}
