# Simbi — Spec v0.6

An open-source macOS notetaking app that lives symbiotically with the Codex
(ChatGPT desktop) app. Simbi records and diarizes audio locally, transcribes it
through the ChatGPT backend, and delegates all "intelligence" (transcript
fixing, file conversion, chat) to Codex threads over the bundled
`codex app-server`.

Changes from v0.5: silence flush threshold back to 2 s (the 6 s threshold
made the live transcript trail ~7 s behind in quiet moments); the gap-edge
upload pads from v0.5 stay, retuned to 0.96 s each (12 frames — two pads
must fit inside the minimal 2 s gap so padded uploads never overlap).
Changes from v0.4: silence handling reworked — silences over the threshold
keep pad audio at each edge in the uploads (trailing pad on the segment
before, leading pad on the segment after — fixes resumed speech being
clipped by diarizer onset lag) and discard only the middle as a `NOTE gap`.
Changes from v0.3 (review fixes): `NOTE gap` blocks use `key=value` form —
WebVTT forbids the substring `-->` inside comment blocks; crash recovery
recomputes `state.json` from the cluster scan and clamps the next session
base to the last cue end (algorithm guide §10.3).
Changes from v0.2: no raw audio on disk — the continuous recording is also
WebM/Opus (one codec/container everywhere); libwebm vendoring decided.
Changes from v0.1: one recording per note (stop/resume appends), WebM/Opus
mandatory (codex-native), existing OSS markdown editor component, system audio
capture in scope, per-feature model selector, speaker-identity-across-notes
dropped.

---

## 1. Stack [decided]

- **Swift 6 + SwiftUI**, macOS 14.0+ (matches FluidAudio's floor; system-audio
  capture path requires 14.4+ — see §3.1).
- **FluidAudio** as an SPM dependency for streaming Sortformer diarization
  (CoreML on ANE, in-process).
- Project layout: a thin Xcode app target (`Simbi.app`) + local SPM packages
  holding all real logic, so `swift build`/`swift test` work headless:
  - `SimbiKit` — notes, file tree, VTT, state, settings
  - `SimbiAudio` — capture (mic + system), diarization, cut-point detection,
    segmenting, Opus/WebM encode + decode (vendored libopus + libwebm)
  - `CodexKit` — app-server JSON-RPC client, transcription API client
- **Markdown editor**: an existing open-source component, not hand-rolled.
  Shipped choice: **swift-markdown-engine** (nodes-app) — native TextKit 2
  live-styled editor (headings, lists, task checkboxes, tables, highlighted
  code blocks via HighlighterSwift, LaTeX via SwiftMath). Pinned exactly
  (pre-1.0). Replaced the M0 pick (STTextView + Neon source editor) on
  2026-07-17; bracket auto-pairing is disabled so typed markdown lands
  verbatim. Fallback if it disappoints: **CodeMirror 6 in a WKWebView** (the
  Obsidian-proven route). Read-only markdown rendering (context file preview)
  uses **MarkdownUI**/Textual.
- Distribution: direct download (not App Store). **App Sandbox off** — we must
  spawn the codex binary, read `~/.codex/auth.json`, and write `~/Simbi`.
  Hardened runtime + notarization for release builds.
- Entitlements/Info.plist: microphone usage description; audio-input device
  access; system-audio capture usage description (§3.1).

## 2. Home directory & note model

### 2.1 Home directory [decided]

- `~/Simbi`, created on first launch.
- The sidebar file tree mirrors the **actual** directory structure — no
  database, no index. FSEvents watcher keeps the tree live; external edits
  (Finder, Codex, git) show up immediately.
- On first launch Simbi also writes `~/Simbi/AGENTS.md` describing the layout
  and conventions below, so any Codex thread opened at the home root
  understands the world without per-thread boilerplate.
- App-global settings live in `~/Simbi/.simbi/settings.json` (files, not a
  database — consistent with everything else).

### 2.2 Note folders [decided]

A folder containing `note.md` is a **note folder** (a leaf in the tree UI).
Folders without `note.md` are organizational parents. The app never creates a
note folder inside another note folder, and the UI prevents it.

**Each note contains exactly one recording.** The user can stop and later
resume recording in the same note; new audio and cues are **appended** to the
same files (§3.5). Note folder layout:

```
~/Simbi/Work/ProjectX/2026-07-15 Standup/     <- note folder
  note.md                # marker + the user's own markdown note
  audio.webm             # the single continuous recording (all sessions), Opus
  transcript.vtt         # the single WebVTT transcript (all sessions)
  files/                 # user-added input files (originals, untouched)
    slides.pdf
  context/               # codex-converted markdown mirrors of files/
    slides.pdf.md
  .simbi/
    state.json           # thread ids, job state, session boundaries
```

- Everything is plain files inside the note folder. No databases anywhere.
- `files/`, `context/`, `.simbi/` are internal structure and are NOT shown as
  children in the sidebar tree (the note is a leaf); they're surfaced inside
  the note view instead.

## 3. Recording & diarization pipeline

### 3.1 Capture [decided: mic + system audio]

- **Microphone**: `AVAudioEngine` input-node tap. The input device is
  selectable (CoreAudio device UID persisted in settings; nil = system
  default), and the mic can be turned off entirely.
- **System audio** (the other side of a call, videos, etc.): CoreAudio
  **process tap** (`CATapDescription` + aggregate device, macOS 14.4+),
  capturing system-wide output. Requires the system-audio-recording TCC
  permission (prompted on first use). Record UI has a sources menu: mic
  (off / default / specific device) and system audio (on / off) chosen
  independently, at least one always on (default: mic + system).
- Both sources are resampled to **16 kHz mono Float32** and mixed (simple sum
  with per-source gain, soft-clip limiter) into ONE stream. The mixed stream
  is the sole input to everything downstream — diarizer, continuous file,
  segment buffer — so timestamps can never diverge between sources.
- The mixed stream feeds three sinks:
  1. **Continuous file writer** — appends to `audio.webm` from t=0 of the
     note's timeline, including in-session silences. This file is the
     timestamp ground truth. **No raw audio ever touches disk**: samples are
     encoded straight to Opus (~24 kbps VBR mono, ~11 MB/hour) and muxed as
     WebM in **live/streaming mode** (no seek head, no duration element —
     nothing to finalize), which makes the file inherently crash-tolerant
     and appendable: a resumed session just writes further clusters.
     Same codec, container, and vendored encoder as the upload segments
     (§3.3) — one audio format everywhere, codex-native.
     In-app playback/seek is our own small path: libwebm parse (a cluster
     index is built once at note-open) + libopus decode → PCM buffers
     scheduled on an `AVAudioPlayerNode`. AVFoundation cannot play WebM;
     this is the accepted cost of the single-format design.
  2. **Sortformer diarizer** — `SortformerDiarizer(config: .fastV2_1)`
     (~1.04 s output latency — the "1 second latency mode"), fp16, ANE.
  3. **Segment ring buffer** — raw samples retained **in memory only**, long
     enough to slice segments once cut points are finalized (target 15 s,
     growable — never evicts samples still referenced by an open segment;
     retention bound proven in the algorithm guide §8).

### 3.2 Cut-point detection [numbers tunable]

> **Normative reference**: the exact algorithm — constants in frames, run
> smoother, buffer-manager state machine, event ordering, pseudocode, worked
> scenarios — is `docs/recording-algorithm.md`. This section is the summary;
> on any disagreement, the guide wins.

Runs on the diarizer's **finalized** frame probabilities only (80 ms
resolution, ~1.04 s behind realtime, delivered in bursts of 6 frames /
480 ms — so every "immediate" trigger below can overshoot by up to 400 ms).
Tentative predictions are used for the live UI speaker indicator, never for
cutting. We consume raw finalized predictions, NOT the library's
`SortformerTimeline` segments (those are emitted late and merge gaps —
verified unsuitable for cut decisions; timeline kept for tentative UI only).

Definitions per finalized frame:
- A speaker slot is *active* if its probability ≥ 0.5.
- *Frame label* = SILENCE if no slot active, else the argmax over active
  slots (tie → lowest slot index). Overlap is resolved per-frame by argmax;
  flicker is absorbed by the run smoother.
- **Debouncing is ours**: FluidAudio's default timeline config applies no
  min-duration smoothing (`minFramesOn/Off = 0` — the 0.25 s/0.1 s values in
  its docs are examples, not defaults). Simbi's run smoother enforces
  `MIN_SPEECH_FRAMES = 3` (0.24 s) and `MIN_SILENCE_FRAMES = 2` (0.16 s):
  shorter runs are absorbed into their neighbors.

Cutting is deliberately **sensitive**; discarding is deliberately
**conservative**. A cut point closes the current segment at every:

1. **Speaker switch** — current speaker changes A→B: cut at the boundary
   frame.
2. **Speech → silence transition** — cut the moment a speech run ends
   (post-smoothing).
3. **Silence → speech transition** — cut the moment speech starts
   (post-smoothing).

Every segment is therefore homogeneous by construction: **pure
single-speaker speech** or **pure silence**.

Buffering & flush (per note, one active upload buffer):
- **Closed speech segments** append to the upload buffer. The buffer is
  single-speaker by construction (a speaker switch flushes it first).
- **Closed silence segments < 2.0 s** (a closed silence segment is always
  followed by speech) glue into the buffer **only when the following speech
  is the same speaker as the buffer** — keeping the audio natural for the
  ASR. A silence run commits only once its successor run is stable, so the
  successor's speaker is always known at glue-decision time; if the
  successor is a different speaker, the buffer flushes at the switch and the
  silence is not uploaded. Glued silences never trigger a flush and are
  never uploaded alone.
- **An open silence run crossing 2.0 s** flushes the buffer immediately (the
  speaker has genuinely paused) and the silence's **middle is discarded** —
  but 0.96 s at each edge stays in the uploads: the flushed segment carries
  the first 0.96 s of the silence as a trailing pad (the audio doesn't cut
  off abruptly), and the next segment's upload starts 0.96 s before its
  detected speech (the diarizer's onset probability ramps up over ~0.5–1 s
  after a pause; the leading pad keeps late-detected speech from being
  clipped out of the transcript). Two pads always fit inside a gap
  (2 × 0.96 s < 2.0 s), so adjacent uploads never overlap. The pads are
  upload-only: cue timestamps stay on the speech extents, `audio.webm`
  contains the whole silence, and the full silence extent gets a
  `NOTE gap start=<start> end=<end>` block in the VTT.
- The buffer is flushed to transcription when any of these fires:
  a) **speaker switch**;
  b) **buffered duration ≥ 10 s** — prefer cutting at the most recent
     segment boundary (a silence↔speech transition) if one exists in the
     last 3 s of the buffer, else hard-cut at the newest finalized frame and
     mark the next segment as a *continuation* (same speaker) in cue
     metadata;
  c) **an open silence run crossing 2.0 s**;
  d) **recording stop** (final flush after `finalizeSession()`).
- Each flushed buffer becomes one upload and one cue: cue start = first
  buffered sample, cue end = last buffered **speech** sample (trailing
  silence at flush time is trimmed from the cue; the upload keeps up to the
  0.96 s pad on a long-silence flush, and none otherwise).
- Speech shorter than 0.25 s between cuts is dropped (below
  `minDurationOn`) — sub-quarter-second blips aren't worth an upload.

### 3.3 Transcription [decided: WebM/Opus, codex-native]

- Endpoint: `POST https://chatgpt.com/backend-api/transcribe` with
  `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id`, and the Codex
  Desktop `originator`/`User-Agent` headers, credentials read from
  `~/.codex/auth.json` (see `references/codex-transcription/transcribe.mjs`).
- Segments are uploaded as **`audio/webm;codecs=opus` — always**, byte-format
  identical to what Codex Desktop itself sends, even if the backend would
  accept other formats. This keeps Simbi indistinguishable from first-party
  traffic and immune to server-side format tightening.
- Encoder: vendored **libopus + libwebm** [decided]. Segment slices (16 kHz
  mono PCM) → Opus @ ~24 kbps VBR → WebM. The same encoder path produces the
  continuous `audio.webm` (§3.1). Building and validating this encoder
  against the endpoint is the M1 spike.
- Every flushed segment is persisted (encoded WebM + sidecar JSON) to
  `.simbi/pending/` at flush time; the upload queue is **disk-backed**, so
  uploads slower than cuts can never grow unbounded in memory, and in-flight
  segments survive a crash for free.
- Up to **2 concurrent uploads**; each retried up to 3× with backoff.
- Results can return out of order; cues are **written to the VTT strictly in
  timestamp order** — a completed later segment waits for its predecessors
  (or their terminal failure) before being appended. A failed segment gets a
  cue with payload `[inaudible]` so the timeline stays complete.

### 3.4 WebVTT format

`transcript.vtt` is the single source of truth for the transcript and is
rendered live by the app. Shape:

```
WEBVTT

NOTE simbi note="2026-07-15 Standup"

NOTE session 1 start=2026-07-15T13:40:00+09:00 offset=00:00:00.000

1
00:00:00.000 --> 00:00:07.360
<v Speaker 1>So the main thing for today is the pipeline refactor.

NOTE gap start=00:00:07.360 end=00:00:12.480

2
00:00:12.480 --> 00:00:19.360
<v Speaker 2>Right, and I think we should land it before Thursday.

NOTE session 1 end=2026-07-15T13:52:10+09:00 offset=00:12:10.240

NOTE session 2 start=2026-07-15T15:03:22+09:00 offset=00:12:10.240

3
00:12:11.700 --> 00:12:15.020
<v Speaker 1>Okay, picking up where we left off.
```

- Cue identifiers are monotonically increasing integers (append order),
  continuing across sessions.
- `NOTE` payloads never contain the substring `-->` — WebVTT forbids it
  inside comment blocks (a parser would read the line as a cue timing).
  Hence the `key=value` form of the `gap`/`session` blocks.
- Timestamps are **note-timeline time**: the contiguous timeline of
  `audio.webm`. A stop/resume adds **zero** timeline time — session 2's first
  sample lands immediately after session 1's last (cluster timecodes continue
  from the previous session's end). Wall-clock reality is recorded in the
  `NOTE session` blocks (and `.simbi/state.json`), so nothing about the pause
  is lost, and cue timestamps always seek correctly into `audio.webm`.
- Speaker labels are `Speaker 1..4` (Sortformer slots) until renamed; a
  rename (by the user in the UI, or by the fixer thread when speakers
  identify themselves) rewrites the `<v>` tags consistently.

### 3.5 Stop / resume semantics [decided: one recording per note]

- **Stop** feeds 2.0 s of zero samples to the **diarizer only** (never to
  `audio.webm` or the ring buffer) before `finalizeSession()` — verified
  necessary: finalization alone drains only whole right-context chunks and
  can leave the trailing ~0.5 s unprocessed. Frames beyond the real audio
  are force-labeled silence and cue ends are clamped to real audio. Then the
  trailing segment flushes to transcription, the last WebM cluster is
  flushed (live-mode: no file finalization needed), and the
  `NOTE session N end` block is written.
- **Resume** in the same note:
  - opens `audio.webm` for append; the timeline offset = end of the last
    cluster (computed from the cluster index built at note-open);
  - starts a **fresh Sortformer session** (streaming state is not preserved
    across sessions — spkcache/FIFO restart cold). Consequence: slot
    numbering may differ between sessions (session 1's "Speaker 2" could be
    session 2's "Speaker 1"). Mitigation is the fixer thread + user rename:
    the fixer is explicitly told about session boundaries and instructed to
    unify `<v>` names across sessions when identity is clear from content;
  - writes the `NOTE session N start` block and continues cue numbering;
  - reuses the note's existing fixer thread via `thread/resume` (§5.2).
- Recording is only appendable while the note's `audio.webm` exists and
  matches `state.json` bookkeeping; mismatch (user swapped files externally)
  disables resume with a clear error rather than corrupting the timeline.

## 4. Live rendering [decided]

- The note view renders `transcript.vtt` from disk, re-parsed on every file
  change (FSEvents/DispatchSource on the file). App-appended cues and
  fixer-thread edits go through the exact same path.
- The parser is strict; if a write leaves the file invalid, the UI keeps the
  last good render and shows a small "transcript temporarily invalid" badge.
  (The fixer is instructed to always leave a valid file, so this badge is a
  bug signal, not a normal state.)
- Tentative (not yet finalized) diarization is shown as a lightweight live
  indicator ("Speaker 2 speaking…"), not as transcript content.

## 5. Codex integration

### 5.1 App-server client

- `CodexKit` spawns `/Applications/ChatGPT.app/Contents/Resources/codex
  app-server` with `CODEX_HOME=$HOME/.codex` (mandatory — see
  `references/codex-open/README.md`), speaking JSON-RPC 2.0 over stdio.
  One long-lived process per app session; auto-restart on crash and reattach
  via `thread/resume`.
- Every programmatically created thread is **named immediately** (a bare
  `thread/start` doesn't persist) with a recognizable prefix, e.g.
  `[simbi] fixer: 2026-07-15 Standup`.
- Worker threads (fixer, converter) run with `approvalPolicy: never` and a
  workspace-write **sandbox scoped to the note folder**, so they never block
  on approvals and can't write outside the note.
- Worker threads are **archived** (`thread/archive`) when their job ends, so
  they don't clutter the Codex app's thread list. Chat threads are never
  archived by Simbi.
- Idle/busy detection via turn lifecycle notifications; `.simbi/state.json`
  records thread ids so a restarted app can resume or re-create workers.

### 5.2 Transcript-fixer thread

- **One fixer thread per note**, created on the note's first recording start
  (`thread/start`, `cwd = <note folder>`), **resumed** (`thread/resume`) on
  recording resume and after app restarts. Instruction turn explains:
  - read `transcript.vtt` and all of `context/*.md` (full note context);
  - on each ping, fix ASR errors in cues appended since the last pass —
    spelling of names/jargon (use context files!), punctuation, obvious
    mis-hearings;
  - **every edit must leave the file as valid WebVTT** (the app renders it
    live); never renumber cues, never change timestamps;
  - speaker `<v>` tags may be renamed only when the transcript makes the
    identity unambiguous, and then consistently across the file;
  - `NOTE session` blocks mark stop/resume boundaries; Sortformer slot
    numbering may reshuffle across them — unify speaker names across sessions
    when identity is clear.
- Ping policy: ping when (a) ≥ 1 new cue has been appended since the fixer's
  last pass AND (b) the thread has no active turn. Pings are coalesced — one
  ping covers everything new. A final ping fires at recording stop.
- The ping is a normal `turn/start` ("Cues N..M are new — review and fix.").
- Archived when the note's recording is stopped and all pings are drained;
  un-archived/resumed if recording resumes.

### 5.3 File-import converter threads

- UI: drag-and-drop / file-picker onto the note view → file is **copied** into
  `files/` (original never modified).
- Each new file spawns a converter job: `thread/start` (cwd = note folder) +
  one turn instructing it to convert `files/<name>` to `context/<name>.md`:
  - the prompt lists known starting points (`textutil`, `mdls`, `sips`,
    `python3`) but explicitly tells the agent to **find its own way to read
    the format** if none fit;
  - hard requirement: **no information loss** — prefer verbose fidelity over
    pretty summarization; tables stay tables, numbers stay exact;
  - images/figures are described in place.
- Job status (converting / done / failed) is shown on the file row in the UI;
  state lives in `.simbi/state.json`. Thread archived on completion.
- Every worker thread created for this note (fixer, future workers) is
  pointed at `context/*.md`, so accumulated context compounds.

### 5.4 "Chat in Codex"

- Button on the note view. Flow:
  1. `thread/start` with **`cwd = ~/Simbi`** (home root — never the note
     folder, so the Codex app's thread history stays clean and browsable);
  2. `thread/name/set` → e.g. `2026-07-15 Standup — chat`;
  3. `turn/start` with a context prompt: "The user wants to discuss the note
     at `Work/ProjectX/2026-07-15 Standup/`. Read its `note.md`,
     `transcript.vtt`, and `context/*.md`, then answer their next message.";
  4. `open codex://threads/<id>` — focuses the ChatGPT app on the thread.
- Note: the composer cannot be pre-filled via deeplink; the context prompt is
  the first turn instead, and the agent is reading the note while the user
  types their question.

### 5.5 Model selection [decided]

- Settings has a **per-feature model selector**: one picker each for
  *transcript fixer*, *file converter*, and *chat threads*.
- Options are populated from the app-server's `model/list`; the first entry
  is always **"Default"** (= don't override, use the thread's default model)
  and is the default for all three features.
- A non-default choice is applied via `turn/start`'s `model` (and optionally
  `effort`) override on that feature's turns.
- Stored in `~/Simbi/.simbi/settings.json`.

## 6. App UI

- **Sidebar**: file tree of `~/Simbi`. Parents expandable; notes are leaves
  (distinct icon). Context menu: new note, new folder, rename, move, reveal in
  Finder, delete (to Trash). All operations are plain FS operations.
- **Note view** (when a note is selected):
  - title (folder name) + `note.md` editor (swift-markdown-engine, §1);
  - **Record / Stop / Resume** button reflecting §3.5, with live elapsed
    time (note-timeline), sources menu (mic device picker + system audio
    toggle, §3.1), and live speaker indicator;
  - transcript pane rendering `transcript.vtt` live, per-speaker colors,
    session-boundary markers, click-to-seek playback of `audio.webm` (via
    the libopus/libwebm playback path, §3.1);
  - speaker rename control (updates `<v>` tags across the file);
  - files section: drag-drop target, one row per `files/` entry with
    conversion status and a link to its `context/` markdown;
  - **Chat in Codex** button (§5.4).
- **Settings**: model selectors (§5.5), audio source defaults, home-folder
  reveal.
- **Empty/degraded states**: if ChatGPT.app or `~/.codex/auth.json` is
  missing, recording+diarization still work; transcription segments queue on
  disk and a banner explains what's disabled.

## 7. Failure & edge behavior

- **App-server dies** mid-recording → recording/diarization unaffected;
  CodexKit restarts it, `thread/resume`s the fixer, re-pings.
- **Transcription auth expires** → segments queue (encoded WebM, on disk in
  `.simbi/pending/`); banner prompts to open ChatGPT app; queue drains on
  recovery.
- **App crash/quit mid-recording** → `audio.webm` (live-mode: valid without
  finalization) and `transcript.vtt` are flushed continuously, so at most
  ~1–2 s of tail audio and any in-flight segments are lost; on relaunch, the
  unfinished session is closed cleanly per the algorithm guide §10.3: a
  truncated trailing cluster is dropped, `state.json.totalSamples` is
  recomputed from the cluster scan and clamped to the last cue's end (so a
  later session can never overlap cues written just before the crash), and
  `NOTE session N end` is written from last known state. The note is then
  resumable.
- **> 4 speakers** → Sortformer's hard limit; extra speakers get merged into
  existing slots. Documented limitation, no mitigation in v1.
- **Fixer writes invalid VTT** → renderer keeps last good state (§4); the
  next ping tells the fixer the file failed to parse and to repair it.
- **System-audio permission denied** → capture proceeds mic-only with a
  banner; the toggle deep-links to System Settings.

## 8. Milestones

- **M0 — skeleton**: repo layout, Xcode app shell + SPM packages, CI
  (`swift build`, `swift test`, swift-format), FluidAudio dependency
  resolving, empty three-pane UI with a working file tree over `~/Simbi`,
  markdown-editor component validated (STTextView + Neon spike).
- **M1 — spike the two risky externals** (throwaway CLIs):
  a) **Opus/WebM encode + decode**: vendored libopus + libwebm; encoder
  output accepted by `backend-api/transcribe` (byte-compatible with Codex
  Desktop uploads); live-mode append + cluster-index seek + decode round-trip
  verified;
  b) app-server round-trip: start thread → turn → notifications → archive →
  resume.
- **M2 — recording pipeline**: mic capture → sortformer → cut points →
  segments → `audio.webm` + VTT appending (stub transcriber), live rendering,
  stop/resume append semantics.
- **M3 — real transcription**: WebM/Opus uploads, ordering/queueing/retries.
- **M4 — fixer thread** end-to-end, including cross-session speaker
  unification.
- **M5 — file import + converter threads**.
- **M6 — system audio capture** (process tap, mixing, permissions).
- **M7 — chat-in-codex, model selectors, speaker rename, playback, polish**.

## 9. Open questions

None — all v0.1/v0.2 open questions are resolved: audio is Opus/WebM
everywhere (no raw audio on disk), and the muxer is vendored **libwebm**.
