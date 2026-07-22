# Fixer activity button/popover verification — 2026-07-19

The recording header gained a transcript-fixer status button (SPEC.md
§5.2): a sparkles icon left of the sources menu — gray while waiting,
tinted + pulsing while a pass runs — whose popover shows a coarse
one-line activity feed (pass started / fixer summary messages / merged
fix counts). Verified in `SIMBI_UI_PREVIEW=1` mode (which forces the
button visible without recording); no recording started, no audio
played.

- **01-fixer-button.png** — sparkles button present in the header,
  immediately left of the mic/system sources menu.
- **02-fixer-popover.png** — round 1 (popover design, superseded):
  headline + empty state rendered correctly.

## Round 2 — reworked into a real window

Per feedback, the popover became a standalone per-note window
(`WindowGroup(for: URL.self)`, opened via `openWindow` from the
sparkles button).

- **03-fixer-window-open.png** — separate window titled
  "Fixer — 2026-07-18 Note 4" with traffic-light controls, movable
  independently of the main window; same headline + activity feed.
  Clicking the sparkles button again focused this window (WindowServer
  confirmed only one fixer window) instead of duplicating it.
- **04-fixer-window-closed.png** — the close button dismisses it; the
  main window remains.

## Result

PASS — button placement, window open/focus/close, and empty state all
correct. The live feed (pass milestones, agent one-liners via the
app-server `item/completed` agentMessage notifications, merge counts)
exercises on the next real recording with Codex connected.
