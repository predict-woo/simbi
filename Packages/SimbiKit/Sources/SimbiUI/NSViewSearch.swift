import AppKit

extension NSView {
    /// Depth-first search of the subtree (self included) for the first view
    /// matching `predicate` — the one recursive walk behind every
    /// AppKit-internals lookup (toolbar title view, outline scroll view).
    func firstDescendant(where predicate: (NSView) -> Bool) -> NSView? {
        if predicate(self) { return self }
        for subview in subviews {
            if let found = subview.firstDescendant(where: predicate) { return found }
        }
        return nil
    }
}
