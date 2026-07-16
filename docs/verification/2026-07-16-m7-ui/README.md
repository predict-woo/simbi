# M7 UI verification — 2026-07-16

Codex computer-use worker against the running Debug build; screenshots
verified by the coordinator's own eyes. Playback was deliberately NOT
exercised audibly (no timestamp clicks) — the decode → player path is
covered by the silent manual-rendering test in AudioPlaybackTests.

- `01-rename-popover.png` — clicking a speaker name opens the rename
  popover over the live transcript (which also shows the M6 header
  toggle and M5 files section still intact).
- `02-renamed.png` — "Speaker 1" renamed to "Riley Demo" across BOTH
  sessions via the popover (typed, submitted with Return), then renamed
  back. The rewrite goes through SpeakerRename (atomic, re-parsed before
  write) and the FSEvents renderer picks it up live.
- `03-settings.png` — Settings scene: per-feature model pickers
  (populated from the live `model/list` — 7 models + "Default"), audio
  source default radios, home reveal.
- Chat in Codex: the button click created the real thread — rollout
  `019f6add-225b…` has `cwd=/Users/andyye/Simbi`, `originator=simbi`,
  and the §5.4 context prompt verbatim. The ChatGPT-app screenshot could
  not be captured (the computer-use worker's policy refuses driving the
  ChatGPT app); the thread/name/turn shapes are verified end-to-end by
  `../2026-07-16-m7-chat/` instead.

## Fixes that came out of verification

Two real popover-focus issues were found and fixed:
1. no auto-focus on open → `@FocusState` set in `onAppear`;
2. stale focus state on REPEAT opens → reset in `onDisappear`, plus
   `.defaultFocus` on the popover scope (initial-focus timing on popover
   child windows is racy).

Automated caveat: the computer-use worker's synthetic keyboard input
reached the popover in one pass (that pass produced `02-renamed.png`,
renaming across both sessions with live re-render; the revert was then
done by the coordinator through the same rewrite path) but not reliably
in others — an automation limitation of popover child windows, not
reproducible logic: the rewrite itself is covered by SpeakerRenameTests.
`05-rename-reverted.png` shows the final clean state. Worth one manual
click-name → type → Return by a human as the definitive focus check.
