# Terminal chat — real-app verification

Verified on the Debug build (worktree `codex-terminal-spike`, commit after
the launch-quoting fixes) with a seeded note `~/Simbi/Codex Terminal Demo`
(note.md, transcript.vtt saying the demo ships Thursday, context/agenda.md).
UI driven by an Orca-orchestrated Codex Computer-Use worker; screenshots
re-read by the coordinator.

- `01-chat-window-tui.png` — Note toolbar → Chat opens "Chat — Codex
  Terminal Demo" hosting the embedded Ghostty surface; the packaged codex
  TUI boots with `directory: ~/Simbi/Codex Terminal Demo` (the `-C` note
  cwd) and an empty, focused composer.
- `02-codex-answer.png` — typed "What does the transcript say about the
  demo date?"; codex searched `transcript.vtt` itself and answered "The
  demo is scheduled to ship Thursday, provided the terminal lands." —
  proving cwd, file access, and the turn loop end-to-end. The user's own
  `~/.codex` hooks ran, confirming personal codex config is honored.

Launch-command traps found during verification (now unit-tested):
Ghostty runs `command` via `bash -c "exec -l <value>"` — a leading `exec`
in the value becomes `exec exec` and fails — and strips a matching pair of
surrounding double quotes from the value, so it must neither start nor end
with `"`. Tokenization was additionally validated by substituting an
argv-dumping script for the codex binary under the exact wrapper.
