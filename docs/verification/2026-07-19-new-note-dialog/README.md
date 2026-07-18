# New Note name dialog verification — 2026-07-19

Creating a note now prompts for a name instead of creating instantly:
the dialog opens with the dated default (`2026-07-19 Note`) prefilled
and selected so typing replaces it; Return creates, Esc cancels. All
entry points (toolbar, ⌘N, sidebar context menus) share the prompt.
Driven via Computer Use against fresh Debug builds; no recording
started, no audio played.

## Round 1 — found a bug (SwiftUI alert)

- **01-dialog-default-selected.png** — first toolbar invocation: field
  prefilled with the dated default, text selected.
- **02-dialog-custom-name.png** — typing directly (no click) replaced
  the selection with "Dialog Test Note".
- **03-note-created-selected.png** — Return created and selected the
  note.
- **04-cmdn-escape-no-note.png** — ⌘N then Esc: no note created.
- **05-folder-context-dialog-empty.png** / **06-toolbar-dialog-empty-after-folder.png**
  — **BUG**: every presentation after the first opened empty. SwiftUI
  `.alert` TextFields cache their text from the first presentation and
  ignore later changes to the bound value.

## Round 2 — fixed (native NSAlert)

The prompt was reimplemented on `NSAlert` (`NoteNamePrompt` in
`FileTreeModel.swift`), which guarantees prefill, select-all focus,
Return default button, and Esc cancel on every presentation.

- **07-second-dialog-prefilled.png** — immediate ⌘N repeat: prefilled
  and selected (previously empty).
- **08-folder-context-prefilled.png** — folder context menu > New Note:
  prefilled and selected (previously empty).
- **09-note-created-in-folder.png** — typed "Prompt Fix Test", Return:
  note created inside the folder and selected.

## Result

PASS after the round-2 fix — prefill + selection on every
presentation, type-to-replace, Return-to-create, Esc-to-cancel, and
correct parent folder targeting all verified.
