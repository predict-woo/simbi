# M3 real-transcription verification — 2026-07-16

All verification was silent (no audio playback, no audio-device changes).

## Headless end-to-end with real diarization AND real transcription

`swift run --package-path Packages/SimbiKit simbi-pipeline-spike --real`
— synthesized two voices to files, fed PCM straight into the pipeline,
segments uploaded to the real `backend-api/transcribe`:

```
cue 1 [Speaker 1]: Hello, this is the first speaker. I am talking about the
                   Symbi recording pipeline, and I will keep going long
                   enough to make a solid first segment.
cue 2 [Speaker 2]: a completely different second speaker, with a lower
                   voice, responding right after the first one finished talking.
cue 3 [Speaker 1]: Back again after resuming the recording in a brand new session.
PASS sessions / cues (gapless, disjoint, ordered) / resume / audio / state
OVERALL: PASS
```

("Symbi" vs "Simbi" is an ASR spelling error — exactly the class of fix
the M4 fixer thread owns.)

## UI render check (Codex worker, read-only, no audio)

`01-real-transcript-rendered.png`: the app renders the real transcript —
Speaker 1 blue / Speaker 2 green, the "silence · 3.0 s" gap row, Session
1/2 dividers, header "Resume · 00:23", Codex connected footer.

## Bug found and fixed during verification

The first `--real` run duplicated cues: session 2's `start()` re-enqueued
pending segments whose uploads were merely still in flight (instant with
the M2 stub, seconds with real network), rendering them a second time as
`[inaudible]`. Start-time re-enqueue now skips cues already tracked by the
live pipeline instance — it exists only for cross-restart recovery.
