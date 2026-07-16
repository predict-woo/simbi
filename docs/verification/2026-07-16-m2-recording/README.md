# M2 recording-pipeline verification — 2026-07-16

Two complementary verifications of the M2 pipeline (mic → Sortformer → cut
points → segments → audio.webm + VTT with stub transcriber, stop/resume).

## 1. Live app run (Codex worker, real microphone)

The worker recorded real `say` speech through the MacBook microphone in the
running app (screenshots `00`–`06`). Verified live: model download in the
"Preparing…" state, elapsed timer, the "Speaker 1 speaking…" tentative
indicator, and a transcript with correctly diarized cues and ≥ 2 s gaps:

```
1  00:00:39.040 --> 00:00:42.560  <v Speaker 1>
2  00:00:43.200 --> 00:00:43.520  <v Speaker 2>
NOTE gap start=00:00:43.520 end=00:00:49.695
3  00:00:50.400 --> 00:00:58.489  <v Speaker 2>
```

Stop/resume added session 2 at exactly session 1's end offset (59.380 s) —
zero timeline gap. The run was cut short when macOS re-routed audio to
AirPods mid-test (no audible-audio reruns per user request — hence §2).

The run surfaced three defects, all fixed:

- **Sidebar selection cleared mid-recording** — the FSEvents refresh storm
  from pipeline file writes could transiently clear the selection and tear
  down the note view. Fix: only clear selection when the item is truly gone
  from disk.
- **View teardown killed the recording** and could create a second pipeline
  on the same note. Fix: one shared `RecordingController` per note folder;
  recording continues until Stop is pressed.
- **A thrown flush skipped a cue index** (observed: `nextCueIndex` 5 with 4
  rendered cues). Fix: the counter now advances only after every fallible
  step of the flush has succeeded.

## 2. Silent headless run (real Sortformer models, no audio devices)

`swift run --package-path Packages/SimbiKit simbi-pipeline-spike` —
synthesizes two voices to files (`say -o`, nothing audible) and feeds PCM
straight into `RecordingPipeline`:

```
session 1: 19.6 s audio diarized in 5.4 s (3.6x realtime)
PASS sessions: 1 and 2 both opened and closed
PASS cues: 3 cues, gapless indices, disjoint and ordered
PASS resume: session 2 produced a cue past 19.62 s
INFO speakers detected: ["Speaker 1", "Speaker 2"] · gap notes: 1
PASS audio: audio.webm spans 23396 ms across both sessions
PASS state: sessionCount 2, nextCueIndex 4, no active session
OVERALL: PASS
```

Full output: `headless-real-model-transcript.vtt`. The real model detected
the Samantha→Daniel speaker switch (cue 1 Speaker 1, cue 2 Speaker 2) with
the 3 s pause rendered as a `NOTE gap`, and the resumed session continued
at exactly 19.616 s with gapless cue numbering.

Automated coverage: 50 package tests, including the algorithm guide's §12
worked scenarios frame-exact, the §5 edge table, outbox ordering, ring
eviction bounds, VTT round-trip, and pipeline stop/resume/crash-recovery
integration with a scripted diarizer.
