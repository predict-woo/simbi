# Pipeline Inspector — design

Approved via interactive mockup (claude.ai artifact `ed76d06f`, 2026-07-22).
A live debug window that visualizes the recording pipeline of
`docs/recording-algorithm.md` — the wrapped models, the release clock, the
three buffer pointers, and rules R1–R6 — from the actual data structures,
while recording. A fun side feature: it must cost nothing when closed and
never perturb the pipeline when open.

## Decisions (from mockup review)

- **Separate window**, one per note, following the `FixerActivityWindow`
  pattern (`WindowGroup(id:for:URL.self)` in the app shell; reopening
  focuses). Opened from a waveform button in `RecordingHeader`, visible
  only while recording.
- **Transcript text included**: flushed segments show their cue's
  transcription when it returns (and its upload state before that).
- The window commits to a **dark HUD appearance** (like the approved
  mockup) regardless of system theme — it is an instrument panel.
- Layout mirrors the mockup top-to-bottom: front-end row (PCM counter,
  Wrapped VAD, Wrapped Sortformer, release clock, PCM ring) → timeline
  (VAD lane, speaker lane, buffer band with pointers/segments/discards,
  rule badges) → six rule meters → flush lane with transcript text →
  event log.

## Architecture

Three layers, joined by one bounded stream:

### 1. `CutEngine` trace (SimbiAudio)

The engine currently reports flushes only (`FlushCommand`). The inspector
also needs cuts, discards, and speaker transitions, with rule
attribution. Add an opt-in trace:

- `enum CutEvent: Equatable, Sendable` — `.cut(frame:rule:)`,
  `.flush(FlushCommand)`, `.discard(start:end:)`,
  `.speakerInit(frame:slot:)`, `.speakerChange(frame:from:to:)`.
  `rule` is a small enum (`r1, r4, r5, stop`).
- `var traceEnabled = false` + `private(set) var trace: [CutEvent]` +
  `mutating func drainTrace() -> [CutEvent]`. Appends happen only when
  `traceEnabled` — the engine stays pure and free when tracing is off.
- Expose (read-only) the per-record state the meters need:
  `silenceRun`, `dominantRun`, `previousDominant` (currentSpeaker,
  pointers already public).

### 2. `RecordingPipeline` tap (SimbiAudio)

Same shape as the existing `liveUpdates()`:

- `public struct InspectorUpdate: Sendable` — one emission per `ingest()`
  batch (and per stop-drain), containing only value types:
  - front end: `samplesFed`, `vadChunks`, `sortFramesFinalized`,
    `burstCount`, `ringRetainedSamples`, session base seconds;
  - engine: `frontier`, `cutUpTo`, `flushedUpTo`, `silenceRun`,
    `dominantRun`, `previousDominant`, `currentSpeaker`;
  - `records: [FrameRecord]` released this batch
    (`frame, vadActive, dominantSlot` — usually 0 or 1 entries);
  - `events: [CutEvent]` drained from the engine trace;
  - `uploads: [UploadEvent]` — `.queued(cue:)`, `.started(cue:)`,
    `.finished(cue:text:)`, plus queue depth / in-flight count.
- `public func inspectorUpdates() -> AsyncStream<InspectorUpdate>` —
  stored optional continuation, `bufferingNewest` policy. Subscribing
  sets `engine.traceEnabled = true`; the stream finishing (or being
  replaced) clears it. With no subscriber the per-batch cost is one
  optional check; nothing is built, the ring is never read.
- `RecordingController.inspectorUpdates()` forwards to the pipeline
  (the pipeline is private to the controller).

### 3. UI (SimbiUI + app shell)

- `PipelineInspectorModel` (`@MainActor @Observable`): consumes the
  stream and accumulates render state — per-frame vad/slot ring (capped
  ~2 500 frames ≈ 200 s), segment cards (with reason rule + transcript
  text), merged discard spans, cut marks, timeline badges, capped event
  log with consecutive-R6 coalescing, rule-meter values. Hot per-frame
  arrays are `@ObservationIgnored`; observable properties update at
  record cadence (≤ 12.5 Hz) so SwiftUI isn't invalidated 100×/s.
  Pure helpers (discard merging, log coalescing) live as static
  functions so they are unit-testable without UI.
- `PipelineInspectorWindow` (`windowId = "pipeline-inspector"`), declared
  in `SimbiApp` next to the fixer/chat windows. Content:
  `PipelineInspectorView` with `.preferredColorScheme(.dark)`.
  Not recording → empty state ("Start recording to inspect the
  pipeline"); recording stopped → last state stays with a "session
  ended" banner.
- Timeline drawn with SwiftUI `Canvas` inside
  `TimelineView(.animation(minimumInterval: 1/30))`; the last ~45 s with
  the live head pinned right. Speaker colors come from
  `Design.speakerPalette`, labels "Speaker N" — same language as the
  transcript.
- `RecordingHeader` gains a borderless `waveform.path.ecg` button
  (recording-only, like the fixer button) that opens the window.

## Performance guarantees

1. Closed window: one `if` per PCM batch (same pattern as
   `liveContinuation`); trace disabled, zero allocations.
2. Open window: emissions are small value structs on the existing actor
   turn; the stream is bounded (newest-wins), so a slow UI can never
   back-pressure the actor. No audio samples ever cross the stream.
3. The engine's decision logic is untouched — trace appends are
   side-effect-only and covered by tests asserting identical
   `FlushCommand` output with tracing on and off.

## Testing

- `CutEngineTests`: trace events for each rule scenario (R1/R2/R3/R4
  both branches/R5/R6, leading silence, stop), trace on/off equivalence,
  trace-off emptiness.
- `RecordingPipelineTests`: with fake VAD/diarizer/transcriber — updates
  arrive per batch, released records match pushed records, cue text
  arrives via `.finished`, subscription toggles `traceEnabled`, and the
  no-subscriber path emits nothing.
- Pure helpers (discard merge, R6 log coalescing): direct unit tests.
- UI verified via the `verify` flow with screenshots under
  `docs/verification/2026-07-22-pipeline-inspector/` (silent-room
  recording exercises leading-silence trim; `SIMBI_UI_PREVIEW` pins the
  header button visible for static screenshots).

## Out of scope

- Historical scrub-back past the retained window, persistence of
  inspector data, exporting traces.
- Any change to cut/flush semantics.
