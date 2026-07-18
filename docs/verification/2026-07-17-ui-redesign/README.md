# UI redesign verification — 2026-07-17

Three build-screenshot-critique rounds via the Codex computer-use
worker; every screenshot re-reviewed by the coordinator's own eyes.
The design language lives in `SimbiUI/DesignSystem.swift`: one type
scale (13 UI / 11 meta / 11 tracked section labels / 15 editor), a 4pt
spacing grid (pane insets 16, editor canvas 24), speaker identity as
dot-chips in a stable four-hue palette (indigo/teal/orange/purple — no
red, red belongs to the record control), compact human time (`0:12`,
never `00:00:12.000`), and a single `StatusBanner` for all degraded
states.

## round1/ — first pass

- `r1-transcript-note.png`, `r1-editor-note.png`, `r1-files-note.png`,
  `r1-settings.png` — new chips, session hairlines, compact times,
  file-type icons, sentence-case statuses, grouped settings.
- Found: FILES section misaligned with the editor's text edge; silence
  markers still too loud in gap-heavy transcripts; idle Record read as
  "hot" (red-tinted button).

## round2/ — alignment + record semantics, then light mode

- `r2-empty-selection.png`, `r2-transcript-note.png`,
  `r2-files-note.png` — dark, fixes confirmed.
- `r2b-light-*.png` — forced-light sweep (app-scoped
  `NSRequiresAquaSystemAppearance`). Found two real defects: silence
  markers illegible on white (quaternary → tertiary), and renamed
  speakers changed color every launch (`String.hashValue` is per-process
  seeded → replaced with a stable djb2 hash). Also swapped pink out of
  the palette (read like the record red) and made the system-audio
  toggle a quiet borderless icon — it was the brightest element in the
  window.

## round3/ — rare states + final confirmation

- `r3-rare-states.png` — `SIMBI_UI_PREVIEW=1` launch faking the states
  that can't be reached silently: both orange banners, live-recording
  header (red Stop, pulsing dot, tinted speaker capsule), playback bar.
- `r3-rename-popover.png` — popover focus + styling.
- `r3-light-files.png`, `r3-final-dark-*.png` — silence markers legible
  in both modes, 예상우 stable purple across launches.

Package tests pass (68). The `SIMBI_UI_PREVIEW` flag stays in
`DesignSystem.swift` for future design reviews; it is inert unless the
env var is set at launch.
