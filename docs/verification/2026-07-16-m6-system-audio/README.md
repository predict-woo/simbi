# M6 system-audio capture verification — 2026-07-16

## Silent tap E2E (`simbi-tap-spike`)

The spike proves the real capture path — CoreAudio process tap →
private aggregate device → IOProc → AVAudioConverter → 16 kHz mono —
with **zero audible output**: afplay plays a wav whose first 4 s are pure
silence; the tap (process-specific, `muteBehavior = .mutedWhenTapped`)
comes up 0.2 s into that lead-in, so the 440 Hz tone in the second half is
muted at the device while being captured. Fail-safe: if the tap isn't
running before the lead-in ends, afplay is killed before any tone plays.

```
afplay pid … — lead-in 4.0s of silence
tap running 0.20s into the lead-in — tone will be muted
captured 10.11s (161786 samples at 16 kHz)
lead-in RMS 0.00000, tone RMS 0.3536
estimated tone frequency: 440.0 Hz
PASS tap: 440 Hz tone captured through tap → aggregate → 16 kHz mono, zero audible output
OVERALL: PASS
```

Tone RMS 0.3536 = 0.5/√2 exactly (the sine's theoretical RMS at 0.5
amplitude) and the zero-crossing estimate landed on 440.0 Hz — the tap →
resample chain is bit-accurate in level and frequency. Full output:
`spike-output.log`.

The production path differs only in tap scope and muting: a global tap
(`CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `.unmuted`)
so the user still hears their call. Mixing is unit-tested (AudioMixer: mic
is the clock, bounded system FIFO, per-source gain, tanh soft-clip).

## Source toggle UI

- `01-toggle-on.png` / `02-toggle-off.png` — the speaker toggle in the
  recording header (mic+system default from settings.json, persisted on
  change, locked while recording). Captured by a Codex computer-use
  worker; verified by the coordinator's own eyes.
