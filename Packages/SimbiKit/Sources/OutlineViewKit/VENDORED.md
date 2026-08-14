# Vendored: OutlineView

Copied verbatim from https://github.com/Sameesunkaria/OutlineView
(commit 661a32c6f6db1bbb4349048e3d0fcb6afa5a9d26, MIT — see LICENSE.txt).

Local changes, each marked with a `Local edit (see VENDORED.md)` comment:

- MenuOutlineView.swift (new file): per-row context-menu support —
  `MenuOutlineView` subclass, `OutlineViewController.setContextMenuProvider`,
  and the `OutlineView.contextMenu(_:)` modifier — plus unemphasized (gray)
  row selection: `QuietSelectionRowView` and the `quietRowSelection()`
  modifier — plus selection filtering: the `selectableRows(_:)` modifier
  makes rows failing the predicate unselectable, and a plain click on such
  a row toggles its expansion instead (via the outline view's click action)
  — plus row hover: the `hoverHighlight(color:cornerRadius:)` modifier
  paints a rounded fill under the pointer (`HoverHighlightRowView`, which
  `QuietSelectionRowView` subclasses).
- OutlineViewController.swift: instantiates `MenuOutlineView` instead of
  `NSOutlineView`.
- OutlineView.swift: stores/plumbs `contextMenuProvider`,
  `quietRowSelectionEnabled`, `selectionFilter`, and `hoverHighlight`.
- OutlineViewDelegate.swift: `quietRowSelection` flag; row views use
  `QuietSelectionRowView` when it is set. `selectionFilter` predicate
  backing `outlineView(_:shouldSelectItem:)`. `hoverHighlight` style
  handed to the hover-capable row views.
- AdjustableSeparatorRowView.swift: dropped `final` so
  `QuietSelectionRowView` can subclass it.
- TreeMap.swift: removed a `TreeMap.Node: Equatable` extension that newer
  compilers reject as redundant; fixed a `private (set)` whitespace warning.
- OutlineViewDataSource.swift: stale-snapshot crash fix. NSOutlineView
  stores the item wrappers it was first handed (matched by id-based
  equality) and never swaps them for fresh ones, so with a key-path child
  source over value types a stored wrapper's children go stale; inserting
  a row into an expanded folder then crashed out-of-range during
  `endUpdates`. `numberOfChildrenOfItem`/`isItemExpandable`/`child:ofItem:`
  and the will-expand TreeMap update now resolve the current item from
  `items` by id (`currentItem(_:)`), falling back to the snapshot only for
  items no longer in the tree. Covered by `Tests/OutlineViewKitTests`.

The target compiles in Swift 5 language mode (pre-concurrency AppKit code);
keep upstream files otherwise unmodified so future diffs stay clean.
