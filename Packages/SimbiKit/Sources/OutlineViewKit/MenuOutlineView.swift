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

    /// Paints a rounded `color` fill (radius `cornerRadius`) under the
    /// row the pointer is over. Selected rows keep their selection fill
    /// and never show the hover fill.
    func hoverHighlight(color: NSColor, cornerRadius: CGFloat) -> Self {
        var mutableSelf = self
        mutableSelf.hoverHighlight = (color, cornerRadius)
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

/// Row view that paints a soft rounded fill under the pointer when
/// `hoverStyle` is set. Selection (drawn by the superclass) wins: the
/// hover fill is skipped on selected rows.
@available(macOS 11.0, *)
class HoverHighlightRowView: AdjustableSeparatorRowView {
    var hoverStyle: (color: NSColor, radius: CGFloat)?

    private var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The system's source-list selection draws inset 10 pt from each row
    /// edge (measured off a live selected row on macOS 26); the hover fill
    /// mirrors that so both highlights share one shape.
    private static let sourceListSelectionInset: CGFloat = 10

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected, let hoverStyle else { return }
        hoverStyle.color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: Self.sourceListSelectionInset, dy: 0),
            xRadius: hoverStyle.radius,
            yRadius: hoverStyle.radius
        ).fill()
    }
}

/// Row view whose selection always draws in the unemphasized (gray) style,
/// regardless of first-responder status.
@available(macOS 11.0, *)
final class QuietSelectionRowView: HoverHighlightRowView {
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

    func setHoverHighlight(_ style: (color: NSColor, radius: CGFloat)?) {
        delegate.hoverHighlight = style
    }
}
