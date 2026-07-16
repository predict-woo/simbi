# Silence-pad redesign verification — 2026-07-16

User-reported: after a pause, the first ~1 s of resumed speech was missing
from the transcript. Cause: silences past the discard threshold were
discarded whole, and the diarizer's onset probability ramps up over
~0.5–1 s after a pause — those late-detected frames were classified into
the discarded silence and never uploaded.

Final rules (SPEC v0.6 §3.2, guide §1/§6; iterated with the user from an
interim 6 s/2 s design — the 6 s flush threshold made the live transcript
trail ~7 s behind in quiet moments):

- Silence < 2 s: glued into the upload (same-speaker successor; dropped at
  a speaker switch) — unchanged from the original design.
- Silence ≥ 2 s: flush immediately (transcript appears ~3–4 s after speech
  stops), but only the silence's MIDDLE is discarded (`NOTE gap` covers the
  whole silence). The uploads on both sides each keep 0.96 s (12 frames) of
  the silence's edge: a trailing pad on the segment before (audio doesn't
  cut off abruptly), a leading pad on the segment after — so resumed speech
  the diarizer detects late is still heard by the ASR.
- Pads are upload-only: cue timestamps stay on speech extents, `audio.webm`
  is unchanged, and 2 × 0.96 s < 2.0 s guarantees adjacent padded uploads
  can never overlap (no duplicated words), even for a minimal gap.

Verified:

- Frame-exact: CutEngineTests re-derived (§12 scenarios incl. pads on both
  gap edges, glue at 1.6 s, gap-with-pads across a speaker switch at 4.8 s,
  upload⊇cue invariants incl. no-overlap). 68/68 tests pass.
- Real-model E2E (`simbi-pipeline-spike`, silent as always): a 7 s pause
  between two synthesized speakers produced exactly one `NOTE gap`, three
  disjoint ordered cues, clean stop/resume bookkeeping
  (`spike-output.log`).
