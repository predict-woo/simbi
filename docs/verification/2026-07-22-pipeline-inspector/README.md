# Pipeline Inspector window verification — 2026-07-22

The recording header gained a Pipeline Inspector button (waveform icon,
recording-only): a separate per-note dark-HUD window that live-visualizes
the recording pipeline of `docs/recording-algorithm.md` — front-end boxes
(PCM / Wrapped VAD / Wrapped Sortformer / release clock / PCM ring), the
aligned-record-stream timeline (VAD lane, speaker lane, buffer pointers,
uploaded segments, hatched R6 discards, rule badges), the six rule
meters, the flush lane with per-cue transcript text, and the event log.

Verified in `SIMBI_UI_PREVIEW=1` mode: the inspector plays a scripted
~45 s session through the **real `CutEngine`** (`InspectorPreviewDriver`),
so every cut/flush/discard shown is a genuine engine decision. No
recording started, no audio played. Live-recording data flow is covered
by `PipelineInspectorTests` (tap stream, trace events, cue text).

## Round 1 — found two rendering bugs

- **01-header-button.png** — waveform button present in the recording
  header (left of the sources menu), tooltip "Pipeline Inspector".
- **02-inspector-early.png / 03-inspector-mid.png** — separate window
  "Pipeline Inspector — 2026-07-18 Note 4" opened; boxes, meters, flush
  cards with quoted transcript text and event log all live, **but** the
  timeline canvas was frozen at its first frame (pointers stuck at 0:00,
  no lanes) and the content clipped at the top (status row and ended
  banner hidden).

Fixes: the `Canvas` inside `TimelineView` now captures the tick date
(without it SwiftUI reuses the first render), and the panel scrolls
inside the window (default size 1100×900).

## Round 2 — fixed

- **05-inspector-mid-fixed.png** — mid-session at live 0:40: status row
  visible; timeline animating with VAD ticks, speaker-colored lanes
  (indigo/teal), R2/R4/R4/R3 segment blocks, dashed cut marks, a
  "7.8 s trimmed" hatched span, ✂R1/⇧R3 badges, and moving
  flushed/cut/frontier/live pointers; R6 meter reading
  "TRIMMING — pre-roll 0.96 s".
- **06-inspector-ended-fixed.png** — amber "Session ended" banner, gray
  status dot, the orange Speaker 3 STOP segment with ✂/⇧ STOP badges,
  "8.4 s trimmed" span, and CUE 004 in the flush lane.

## Result

Pass. Separate window per note, opened from the header while recording;
timeline, meters, flush lane (with transcript text) and log all update
live and settle into the session-ended state. Known cosmetic nit: the
flushed/cut/frontier pointer labels crowd together when the pointers
coincide at the live head (session start / deep in an R6 trim).
