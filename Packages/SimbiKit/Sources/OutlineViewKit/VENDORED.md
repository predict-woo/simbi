# Vendored: OutlineView

Copied verbatim from https://github.com/Sameesunkaria/OutlineView
(commit 661a32c6f6db1bbb4349048e3d0fcb6afa5a9d26, MIT — see LICENSE.txt).

Local changes, each marked with a `Local edit (see VENDORED.md)` comment:

- MenuOutlineView.swift (new file): per-row context-menu support —
  `MenuOutlineView` subclass, `OutlineViewController.setContextMenuProvider`,
  and the `OutlineView.contextMenu(_:)` modifier — plus unemphasized (gray)
  row selection: `QuietSelectionRowView` and the `quietRowSelection()`
  modifier.
- OutlineViewController.swift: instantiates `MenuOutlineView` instead of
  `NSOutlineView`.
- OutlineView.swift: stores/plumbs `contextMenuProvider` and
  `quietRowSelectionEnabled`.
- OutlineViewDelegate.swift: `quietRowSelection` flag; row views use
  `QuietSelectionRowView` when it is set.
- AdjustableSeparatorRowView.swift: dropped `final` so
  `QuietSelectionRowView` can subclass it.
- TreeMap.swift: removed a `TreeMap.Node: Equatable` extension that newer
  compilers reject as redundant; fixed a `private (set)` whitespace warning.

The target compiles in Swift 5 language mode (pre-concurrency AppKit code);
keep upstream files otherwise unmodified so future diffs stay clean.
