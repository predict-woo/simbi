# Silence-pad redesign verification — 2026-07-16

User-reported: after a pause, the first ~1 s of resumed speech was missing
from the transcript. Cause: silences ≥ 2 s were discarded whole, and the
diarizer's onset probability ramps up over ~0.5–1 s after a long pause —
those late-detected frames were classified into the discarded silence and
never uploaded.

New rules (SPEC v0.5 §3.2, guide §1/§6):

- Silence ≤ 6 s: glued into the upload like short silences always were
  (same-speaker successor; dropped at a speaker switch).
- Silence > 6 s: only the MIDDLE is discarded (`NOTE gap` covers the whole
  silence). The uploads on both sides each keep 2 s of the silence's edge:
  a trailing pad on the segment before, a leading pad on the segment after
  — so resumed speech the diarizer detects late is still heard by the ASR.
- Pads are upload-only: cue timestamps stay on speech extents, `audio.webm`
  is unchanged, adjacent padded uploads can never overlap (gap ≥ 6 s,
  pads total 4 s).

Verified:

- Frame-exact: CutEngineTests re-derived for the new semantics (§12
  scenarios incl. new §12.3 with pads on both gap edges, glue at 4.8 s,
  drop-at-switch at 4.8 s, upload⊇cue invariants). 68/68 tests pass.
- Real-model E2E (`simbi-pipeline-spike`, silent as always): a 7 s pause
  between two synthesized speakers produced exactly one
  `NOTE gap start=00:00:09.040 end=00:00:16.160`, 3 disjoint ordered cues,
  clean stop/resume bookkeeping (`spike-output.log`).
