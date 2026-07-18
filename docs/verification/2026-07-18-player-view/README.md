# Player view verification — 2026-07-18

Verified the new playback player view against a seeded note
(`~/Simbi/Player Test`: 30 s of **silent** audio.webm + a 10-cue
transcript, 3 s per cue, alternating speakers — silence so the checks
run inaudibly). Three build-test rounds via the Codex computer-use
worker; every screenshot re-reviewed by the coordinator's own eyes.

Features under test: persistent player bar (play/pause, scrubber,
position/duration) above the transcript whenever the note has audio and
isn't recording; the currently playing cue highlighted in its speaker
color and followed by auto-scroll; click a sentence (or its timestamp)
to play from that cue. Models note: diarizer/VAD now preload at app
launch via `SpeechModelPool` — not directly screenshot-able, covered by
`swift test` + code review.

## Round 1 — full pass

- `01-player-bar.png` — player bar present when idle: play button,
  `0:00`, scrubber, `0:30`.
- `02-click-cue-three.png` — **defect**: clicking the sentence glyphs
  did nothing (`.onTapGesture` never fires on
  `.textSelection(.enabled)` text — the selection view consumes the
  click).
- `03-highlight-follows.png` — after seeking via the Cue three
  timestamp, the highlight advanced to Cue four at `0:10` (teal =
  Speaker 2 tint) with playback running.
- `04-paused.png` — pause froze the readout (`0:22`, verified stable
  over 1.5 s).
- `05-timestamp-seek.png` — timestamp click seeks to `0:18`, Cue seven
  highlighted.
- `06-scrubber.png` — scrubbing while paused moved the resume point
  (`0:18` → `0:15`).

## Round 2 — `simultaneousGesture` attempt

- `07-sentence-click-fixed.png` — still inert:
  `.simultaneousGesture(TapGesture())` is *also* swallowed by the
  selection platform view.
- `08-drag-select.png` — drag-to-select itself worked fine.

Conclusion: on macOS, tap-to-play and drag-to-select cannot coexist on
the same glyphs. Chose tap-to-play (the feature request) and replaced
selection with a right-click **Copy** context menu on each sentence.

## Round 3 — final

- `09-sentence-click-final.png` — clicking the Cue three glyphs starts
  playback at `0:06`: pause icon, advancing readout, indigo (Speaker 1)
  row highlight.
- `10-final-paused.png` — right-click menu showed Copy; paused clean at
  `0:26` (position verified stable).
