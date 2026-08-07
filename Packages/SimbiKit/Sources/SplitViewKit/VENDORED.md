# Vendored: SplitView

Copied verbatim from https://github.com/stevengharris/SplitView
(tag 3.5.3, commit 7737a80740919c2fa94a6e64f870d37ef77b9b5f, MIT — see
LICENSE.txt).

Vendored rather than pinned via SPM because upstream has been dormant
since mid-2024: this keeps macOS/Swift fixes in our hands. It replaces
SwiftUI's `HSplitView` in the note view, whose macOS 26 `NSSplitView`
bridge misbehaves three ways: a bogus ~1028 pt window minimum while the
sidebar is open, the pane divider piercing the titlebar after the glass
toolbar drops its launch-time scroll pocket, and the split view
detaching from the window's trailing edge when the window shrinks after
the divider has been dragged (it over-shrinks ~1.5 pt per 1 pt of window
delta, parking at the sum of pane minimums). SplitView is pure SwiftUI
(gesture + frame math), so none of that machinery is involved.

Local changes, each marked with a `Local edit (see VENDORED.md)` comment:

- Repo-wide `swift format` normalization (whitespace/indentation).
- Split.swift: four over-long end-of-line comments moved above their
  lines to satisfy `swift format lint --strict` (EndOfLineComment).
- Split.swift: layout clamps the primary side's length so the secondary
  side's minimum always fits. Upstream only clamps the fraction during
  drags, so a fraction that outgrew `1 - minSFraction` when the window
  shrank pushed the secondary view past the trailing edge, where
  `.clipped()` cut it off instead of it holding its minimum size.

Keep upstream files otherwise unmodified so future diffs stay clean.
