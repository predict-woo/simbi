---
name: verify
description: Build, launch, and UI-verify the Simbi macOS app after a change
---

# Verifying Simbi

## Build + launch

```bash
cd Packages/SimbiKit && swift build && swift test   # fast inner loop
xcodebuild -project Simbi.xcodeproj -scheme Simbi -configuration Debug build
```

App lands in `~/Library/Developer/Xcode/DerivedData/Simbi-*/Build/Products/Debug/Simbi.app`.

**Always kill a stale instance first** — `open` only focuses a running
app, it does not swap in the new binary:

```bash
ps aux | grep "MacOS/Simbi" | grep -v grep   # kill the PID, then:
open ~/Library/Developer/Xcode/DerivedData/Simbi-*/Build/Products/Debug/Simbi.app
```

Confirm the process start time is after the build. To check a feature
is in the binary, grep `Simbi.app/Contents/MacOS/Simbi.debug.dylib`
(the `Simbi` binary itself is a thin ~58KB loader).

## Driving the UI

Delegate desktop automation to a Codex TUI worker via Orca
orchestration (load the `orchestration` skill):
`orca terminal create --worktree active --command codex` → `terminal
wait --for tui-idle` → `task-create` → `dispatch --inject` → `check
--wait --types worker_done,escalation,decision_gate`.

Dispatch specs must include: save evidence under
`docs/verification/<yyyy-mm-dd>-<topic>/` with descriptive filenames
and list paths in worker_done; never work around permission blocks
(stop and report); retry transient Computer Use errors (e.g. -10005
keyNotFound); never play audio or start a recording.

Afterwards the coordinator re-reads the screenshots itself and writes
a `README.md` in the evidence dir (see existing dirs for the format).

## Design-review helpers

- `SIMBI_UI_PREVIEW=1` (env at launch) forces the rare UI states —
  degraded banners, live-recording header, playback bar — without
  recording or playing audio. See `SimbiUI/DesignSystem.swift`.
- Light-mode screenshots without touching the system theme:
  `defaults write ac.clap.simbi NSRequiresAquaSystemAppearance -bool true`,
  relaunch; `defaults delete` it afterwards.

## App data

Notes live in `~/Simbi/<Note Name>/note.md`. Seed a note by writing
that file; it appears in the sidebar (FSEvents). Autosave is debounced
~500 ms — wait ~2 s before checking the file.
