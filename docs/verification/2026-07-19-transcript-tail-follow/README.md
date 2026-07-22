# Transcript tail-follow verification — 2026-07-19

While the transcript pane is scrolled to the bottom, new cues keep it
pinned there; once the user scrolls up to read an earlier segment,
growth must not yank them away. Verified against a "Scroll Test" note
by appending cues to its `transcript.vtt` from a shell (the pane
live-reloads on file change) — no recording, no audio.

## Round 1 — geometry preferences (failed)

At-bottom was tracked with scroll-geometry `PreferenceKey`s. macOS does
not reliably re-fire those during user scrolling, so the flag went
stale:

- 01-at-bottom / 02-followed-tail — following while at bottom: PASS.
- 03-scrolled-up / **04-no-yank — FAIL**: view was around cue 10, an
  appended cue yanked it to the tail.

## Round 2 — row-mount tracking (passed)

"At the bottom" is now structural: the last row is currently mounted by
the `LazyVStack` (rows unmount as the user scrolls away, so the signal
cannot go stale). On growth, the view pins to the new bottom only if
the previous last row was mounted.

- **06-retest-at-bottom.png** — scrolled to the bottom (cue 33).
- **07-retest-followed.png** — appended cue 34: view followed. PASS.
- **08-retest-scrolled-up.png** — scrolled up to ~cue 10.
- **09-retest-no-yank.png** — appended cue 35: view stayed at cues
  1–11, cues 34/35 not shown. PASS (previously the failing case).
- **10-retest-follow-resumes.png** — back at bottom, appended cue 36:
  following resumed. PASS.

## Round 3 — crash fix (row-mount tracking replaced)

Round 2's per-row `onAppear`/`onDisappear` tracking crashed the app in
the field: the LazyVStack cache reinserts rows during
`NSHostingView.layout`, and `AppearanceEffect.didReinsert` then requests
a window constraint update mid-layout-pass — AppKit throws, and the
uncaught exception traps (`NSApplication _crashOnException`). The
mechanism is now `scrollTargetLayout()` + `scrollPosition(id:anchor:
.bottom)` — no per-row effects at all.

- **11-fix-followed.png / 12-fix-no-yank.png / 13-fix-follow-resumes.png**
  — all three behavior checks re-passed.
- **14-stress-alive.png** — crash stress: 8 cues appended ~1s apart
  while continuously flick-scrolling the pane; app stayed alive and
  responsive.

## Result

PASS after round 3 — behavior verified and the layout-reentrancy crash
scenario no longer reproduces.
