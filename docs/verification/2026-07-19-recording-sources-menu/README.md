# Recording sources menu verification — 2026-07-19

The single mic/system speaker toggle in the recording header is now a
two-icon **sources menu** (mic + speaker), and the mic device is
selectable. Verified against a fresh Debug build (PID 89044) driven via
Computer Use; no recording was started and no audio played.

## What was checked

- **01-header-closed.png** — header shows the two-icon menu in place of
  the old toggle; both icons tinted (mic on, system audio on).
- **02-menu-open-defaults.png** — open menu: *Microphone* section with
  Off / ✓ System default / real input devices (MacBook Pro Microphone,
  BlackHole 2ch, …) and a *System audio* section with ✓ Capture system
  audio. Defaults match settings (mic default + system audio on).
- **03-menu-microphone-off.png** — after choosing Off: ✓ Off, header mic
  icon slashed, and **Capture system audio is disabled** (the last
  active source can't be turned off).
- **04-menu-system-audio-off.png** — mic restored, system audio
  unchecked: **Off is disabled** (same guard from the other side),
  header speaker icon slashed.
- **05-settings-recording-defaults.png** / **06-settings-microphone-options.png**
  — Settings › Recording shows the same model: Microphone picker
  (Off / System default / devices) + Capture system audio toggle, values
  in sync with the header menu (choices persist to settings.json).

## Result

PASS — menu contents, checkmarks, both disabled-state guards, header
icon states, and Settings mirroring all behaved as specified
(SPEC.md §3.1).

Follow-up applied after the screenshots: the device list filters out
`CADefaultDeviceAggregate-<pid>-…` (screenshot 02 shows one) — a
transient aggregate CoreAudio publishes for the app's own engine, not a
pickable mic.
