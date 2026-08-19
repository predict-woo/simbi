# Agent feature switches — 2026-08-19

PASS — the Codex settings pane shows native switches for Transcript fixer,
AI notes, and Note title.

- `01-all-off.jpeg` — all three switches disabled.
- `02-all-on.jpeg` — all three switches enabled (the default and restored state).
- Toggling all three off wrote `false` for `transcriptFixerEnabled`,
  `aiNotesEnabled`, and `noteTitleEnabled` in the active `settings.json`.
- `swift test`: 274 tests passed.
- Debug `xcodebuild`: succeeded.

No recording or audio playback was started.
