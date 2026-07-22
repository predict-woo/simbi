# Pipeline Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-note "Pipeline Inspector" window that live-visualizes the recording pipeline's internal data structures (wrapped models, release clock, buffer pointers, rules R1–R6, uploads with transcript text) with zero cost while closed.

**Architecture:** Three layers: (1) an opt-in `CutEngine` trace giving rule-attributed events; (2) a `RecordingPipeline` `AsyncStream<InspectorUpdate>` tap mirroring the existing `liveUpdates()` pattern, plus a pure `InspectorTimelineState` reducer; (3) a SwiftUI dark-HUD window (Canvas timeline + meters + flush lane + log) following the `FixerActivityWindow` per-note-window pattern.

**Tech Stack:** Swift 6 (SPM package SimbiKit), Swift Testing (`@Test`/`#expect`), SwiftUI Canvas, macOS 14+.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-22-pipeline-inspector-design.md`.
- Zero pipeline impact when closed: per-batch cost is one optional check; `traceEnabled` false ⇒ no trace allocations; decision output identical with tracing on/off.
- The stream is bounded (`.bufferingNewest(256)`); no audio samples ever cross it.
- Speaker naming/colors: "Speaker N" + `Design.speakerPalette` (indigo, teal, orange, purple).
- Tests: Swift Testing in `Tests/SimbiAudioTests` (no SimbiUI test target — testable logic lives in SimbiAudio).
- Do not commit without the user's go-ahead (their working tree carries unrelated work).

---

### Task 1: CutEngine trace

**Files:**
- Modify: `Packages/SimbiKit/Sources/SimbiAudio/CutEngine.swift`
- Test: `Packages/SimbiKit/Tests/SimbiAudioTests/CutEngineTests.swift` (new suite section)

**Interfaces (Produces):**

```swift
public enum CutRule: Equatable, Sendable { case r1, r4, r5, stop }

public enum CutEvent: Equatable, Sendable {
    case cut(frame: Int, rule: CutRule)
    case flush(FlushCommand)
    case discard(start: Int, end: Int)
    case speakerInit(frame: Int, slot: Int)
    case speakerChange(frame: Int, from: Int, to: Int)
}

// CutEngine additions:
public var traceEnabled: Bool                      // default false
public private(set) var trace: [CutEvent]
public mutating func drainTrace() -> [CutEvent]
public private(set) var silenceRun: Int            // was private
public private(set) var dominantRun: Int           // was private
public private(set) var previousDominant: Int?     // was private
```

- [x] **Step 1: Write failing tests** — trace disabled by default; R1→R3→R6 scenario event sequence; R4 flush-branch and cut-branch; commands identical with trace on/off:

```swift
@Test("trace is off by default and stays empty")
func traceOffByDefault() {
    var engine = CutEngine()
    _ = push(&engine, count: 40, vadActive: true, slot: 0)
    _ = push(&engine, count: 30, vadActive: false, slot: nil)
    #expect(engine.trace.isEmpty)
}

@Test("trace records R1 cut, R3 flush, R6 discards with attribution")
func traceSilenceScenario() {
    var engine = CutEngine()
    engine.traceEnabled = true
    _ = push(&engine, count: 40, vadActive: true, slot: 0)
    _ = push(&engine, count: 25, vadActive: false, slot: nil)
    let events = engine.drainTrace()
    #expect(events.first == .speakerInit(frame: 5, slot: 0))
    #expect(events.contains(.cut(frame: 43, rule: .r1)))
    #expect(events.contains(.flush(
        FlushCommand(startFrame: 0, endFrame: 43, speaker: 0, reason: .longSilence))))
    #expect(events.contains(.discard(start: 43, end: 53)))
    #expect(engine.trace.isEmpty)  // drained
}

@Test("R4 cut-branch traces cut(mid, .r4) then flush; direct switch")
func traceSpeakerCutBranch() {
    var engine = CutEngine()
    engine.traceEnabled = true
    _ = push(&engine, count: 30, vadActive: true, slot: 0)
    _ = push(&engine, count: 6, vadActive: true, slot: 1)
    let events = engine.drainTrace()
    #expect(events.contains(.cut(frame: 30, rule: .r4)))
    #expect(events.contains(.speakerChange(frame: 35, from: 0, to: 1)))
}

@Test("tracing does not change decisions")
func traceEquivalence() { /* same scripted pushes twice; compare [FlushCommand] */ }
```

- [x] **Step 2: Run to verify failure** — `swift test --filter CutEngineTests` in `Packages/SimbiKit`; expect compile errors (no `trace`).
- [x] **Step 3: Implement** — add enums; thread `rule` through `cut(_:into:...)`; append events in `cut/flush/discard` and the R4/init paths, guarded by `traceEnabled`; widen the three state vars to `public private(set)`.
- [x] **Step 4: Run to verify pass** — full `swift test --filter CutEngineTests`.

### Task 2: InspectorUpdate + RecordingPipeline tap + InspectorTimelineState

**Files:**
- Create: `Packages/SimbiKit/Sources/SimbiAudio/PipelineInspector.swift`
- Modify: `Packages/SimbiKit/Sources/SimbiAudio/RecordingPipeline.swift`
- Test: `Packages/SimbiKit/Tests/SimbiAudioTests/PipelineInspectorTests.swift`

**Interfaces (Produces):**

```swift
public struct InspectorFrameRecord: Equatable, Sendable {
    public let frame: Int
    public let vadActive: Bool
    public let dominantSlot: Int?
}

public enum InspectorUploadEvent: Equatable, Sendable {
    case queued(cue: Int, startFrame: Int, endFrame: Int, speaker: Int?, reason: FlushReason)
    case finished(cue: Int, text: String)
}

public struct InspectorUpdate: Sendable {   // emitted once per ingest batch / upload completion
    public let samplesFed: Int
    public let sessionBaseSeconds: TimeInterval
    public let vadChunks: Int
    public let sortFramesFinalized: Int
    public let frontier: Int
    public let cutUpTo: Int
    public let flushedUpTo: Int
    public let silenceRun: Int
    public let dominantRun: Int
    public let previousDominant: Int?
    public let currentSpeaker: Int?
    public let uploadQueueDepth: Int
    public let uploadsInFlight: Int
    public let records: [InspectorFrameRecord]
    public let events: [CutEvent]
    public let uploadEvents: [InspectorUploadEvent]
}

// RecordingPipeline:
public func inspectorUpdates() -> AsyncStream<InspectorUpdate>

// RecordingController:
public func inspectorUpdates() async -> AsyncStream<InspectorUpdate>

// Pure reducer (value type, UI-free — the UI model wraps it):
public struct InspectorTimelineState: Sendable {
    public struct Span: Equatable, Sendable { public let start: Int; public let end: Int }
    public enum SegmentStatus: Equatable, Sendable { case queued, done(text: String) }
    public struct Segment: Equatable, Sendable, Identifiable { … cue id, frames, speaker, reason, status }
    public struct LogEntry: Equatable, Sendable, Identifiable { … id, frameTimeSec, tag, message }
    public private(set) var frames: [InspectorFrameRecord]   // capped at 2_500
    public private(set) var segments: [Segment]              // capped at 40
    public private(set) var discards: [Span]                 // adjacent-merged
    public private(set) var cutMarks: [Int]
    public private(set) var log: [LogEntry]                  // capped at 60, newest first, R6 coalesced
    public private(set) var latest: InspectorUpdate?
    public mutating func apply(_ update: InspectorUpdate)
}
```

- [x] **Step 1: Failing reducer tests** — discard-merge, R6 log coalescing (one entry that updates while a trim run continues), segment queued→done text, frame cap:

```swift
@Test("adjacent discards merge and coalesce into one log entry")
@Test("a flush becomes a segment; finished(cue:text:) fills its transcript")
@Test("frames buffer is capped")
```

- [x] **Step 2: Failing pipeline-tap test** — fake diarizer/VAD/StubTranscriber (reuse `RecordingPipelineTests` fakes): subscribe, ingest scripted audio, assert records match released frames, a `.queued` then `.finished(text:)` arrive for the first cue, and pointers in the last update equal the engine's.
- [x] **Step 3: Implement** — types + reducer; pipeline: optional continuation, `inspectorRecords` buffer filled in `releaseRecords` only when subscribed, `engine.traceEnabled` toggled on subscribe/finish and re-applied in `start()`, emission at end of `ingest()`/`stop()` and from `uploadFinished` (cue text), upload events collected in `flushSegment`/`uploadFinished`.
- [x] **Step 4: Run** — `swift test --filter PipelineInspectorTests` then the full SimbiAudioTests suite (no regressions).

### Task 3: Inspector window UI + header button + app scene

**Files:**
- Create: `Packages/SimbiKit/Sources/SimbiUI/PipelineInspectorModel.swift`
- Create: `Packages/SimbiKit/Sources/SimbiUI/PipelineInspectorView.swift`
- Modify: `Packages/SimbiKit/Sources/SimbiUI/RecordingController.swift` (forwarder)
- Modify: `Packages/SimbiKit/Sources/SimbiUI/NoteView.swift` (header button)
- Modify: `App/SimbiApp.swift` (WindowGroup)

**Interfaces (Consumes):** Task 2's `inspectorUpdates()` + `InspectorTimelineState`.

- [x] **Step 1: Model** — `@MainActor @Observable PipelineInspectorModel`: `attach(RecordingController)` starts a consume task; hot state (`InspectorTimelineState`) in `@ObservationIgnored` storage read by the Canvas via `TimelineView(.animation(minimumInterval: 1/30))`; observable summary props (meters, cards, log) updated per update batch; `sessionEnded` flag when the stream finishes.
- [x] **Step 2: View** — `PipelineInspectorWindow` (`windowId = "pipeline-inspector"`, dark HUD via `.preferredColorScheme(.dark)`), sections mirroring the approved mockup: front-end row (PCM/VAD/Sortformer/clock/ring), Canvas timeline (ruler, VAD lane, speaker lane, buffer band with pointers + segments + hatched discards + cut marks, rule badges), six rule meters, flush lane (segment cards with `SpeakerChip`-style identity, reason badge, transcript text), event log. Empty state when not recording; "session ended" banner on stream finish.
- [x] **Step 3: Entry points** — `RecordingHeader` gains a `waveform.path.ecg` borderless button (visible while recording or `Design.uiPreview`) calling `openWindow(id:value:)`; `SimbiApp` declares the `WindowGroup("Pipeline Inspector", id:, for: URL.self)` with `.defaultSize(width: 1000, height: 640)`.
- [x] **Step 4: Build** — `swift build` in `Packages/SimbiKit` + full `swift test`.

### Task 4: End-to-end verification

- [x] Build & launch the app (kill any stale instance first — memory: check process start time), start a recording on a scratch note (silent room), open the inspector, confirm: leading-silence R6 trim appears, meters move, window updates live; stop recording → session-ended state.
- [x] Screenshots to `docs/verification/2026-07-22-pipeline-inspector/` with a `notes.md`.
- [x] Full `swift test` green.
