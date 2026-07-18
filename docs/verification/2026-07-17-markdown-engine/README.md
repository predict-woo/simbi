# Markdown-engine editor verification — 2026-07-17

Codex computer-use worker against the running Debug build; screenshots
verified by the coordinator's own eyes. The STTextView + Neon source
editor was replaced with swift-markdown-engine 0.10.0 (TextKit 2
live-styled editor, HighlighterSwift code blocks, SwiftMath LaTeX).

Round 1 (first build):

- `01-rendered-note.png` — seeded note renders live-styled: H1/H2,
  bold/italic/strikethrough/==highlight==/inline-code/link, bullets +
  nesting, ordered list, real task checkboxes, blockquote, table.
- `02-table-code-math.png` — table, highlighted swift code block,
  rendered E=mc² formula.
- `03-typed-live-styling.png` — typed `## heading`, `**bold**`, and a
  task item style live as you type.
- `04-checkbox-toggled.png` — clicking the "Open task" checkbox toggles
  it; `05-note-md-after-edit.txt` shows `- [x] Open task` persisted to
  disk by the debounced autosave (raw markdown round-trips).
- `06-after-undo-redo.png` — 3× Cmd-Z reverted the typed edits, 3×
  Cmd-Shift-Z restored them (per-document undo via `documentId`).
- `07-after-note-switch.png` — switching notes and back keeps content;
  no crash in the HSplitView (the M0 sizeThatFits crash does not recur).

## Fix that came out of verification

Round 1 found typing `- [ ] typed task item` persisted with a stray
trailing `]`. Cause: the engine auto-pairs `[` → `[]` but has no
type-through of the closing bracket, so typing literal markdown syntax
(task boxes, `[text](url)` links) always duplicated a bracket. Fixed by
`config.lists.autoClosePairsEnabled = false` in `MarkdownEditor.swift`
(list continuation and Tab-indent helpers stay on).

Round 2 (after fix, rebuilt + relaunched):

- `08-retyped-brackets.png` / `09-note-md-retest.txt` — typed
  `- [ ] typed task item` and
  `A [real link](https://apple.com) and (parens) and {braces}.` land
  on disk verbatim, no stray brackets. (The second line gained a
  `- [ ]` prefix because Return after a task item continues the list —
  intended editor behavior, not a defect.)
- `10-rendered-typed-content.png` — the typed task renders as a
  checkbox row, the typed link is styled and underlined.

Known quirk (not blocking): after rapid undo/redo the checkbox marker
of the restored task row can render as raw text until the note is
switched away and back — engine restyle timing, content on disk is
correct throughout.
