# Simbi Live Recording Algorithm (v2)

Redesign of the live cut-point pipeline. The previous design derived both
silence cuts and speaker cuts from Sortformer alone, which forced a run
smoother, glue silences, gap discarding, and edge pads. This design drops
silence removal entirely (transcription is server-side; uploading silence is
free) and splits responsibilities:

- **Silero VAD** decides where audio is *cut* on silence (rule R1).
- **Sortformer** provides *speaker labels* and detects *speaker changes*
  (rule R4).
- **Raw PCM ring** holds the audio; it is sliced only when a *flush*
  uploads a span (§5). Nothing else touches audio.

The document builds the design in layers, each usable as a closed mental
model:

1. Raw model facts (§1) — what FluidAudio actually does.
2. Global grid (§2) — the 80 ms frame timeline everything is indexed by.
3. Wrapped per-frame models (§3) — both models repackaged as black boxes
   that consume and emit **80 ms frames** with a known frame latency.
4. The aligned pipeline (§4) — three frame-latency boxes joined by one
   release clock into a single synchronized record stream.
5. Cuts and flushes (§5) — buffer and upload rules over that stream.

All arithmetic is in **samples** (16 kHz mono) and **frames** (80 ms = 1280
samples) unless a rule is explicitly in seconds.

---

## 1. Verified model facts (FluidAudio)

Verified against FluidAudio source (`Sources/FluidAudio/Vad/*.swift`,
`Sources/FluidAudio/Diarizer/Sortformer/*.swift`). The implementation must
not assume anything beyond this list.

### Silero VAD (`VadManager`)

1. Fixed chunk size: **4096 samples = 256 ms** (`VadManager.chunkSize`),
   plus a 64-sample carried context (model input 4160).
2. Streaming and stateful: `makeStreamState()` /
   `processStreamingChunk(_:state:)`; state = LSTM hidden/cell (128 each) +
   64-sample audio context. Input must be contiguous and non-overlapping —
   sliding/overlapping windows would corrupt the recurrence.
3. Output per call: one speech probability for that 256 ms chunk. Results
   are never revised.
4. Coverage lag: with `N` samples fed, verdicts exist through
   `N − (N mod 4096)` — lag **0–4096 samples (0–256 ms)**.

### Sortformer (`.fastV2_1`)

1. Config: `chunkLen = 6`, `chunkLeftContext = 1`, `chunkRightContext = 7`,
   `subsamplingFactor = 8`, `melStride = 160`, `numSpeakers = 4`.
   Output frame = 8 mel frames = **80 ms = 1280 samples**.
2. Internal pipeline: samples → log-mel (10 ms hop) → ×8 subsampling →
   80 ms frames → sliding window of 1 left + **6 core** + 7 right context
   frames (1.12 s). Each model call finalizes the 6 core frames (480 ms)
   and slides forward by 6. `process()` returns `nil` until a full window
   exists, so finalized frames arrive in **bursts of 6**.
3. Carried state: FIFO of 40 frame embeddings (3.2 s recent context) +
   speaker cache of 188 compressed frames (~15 s, refreshed every 31
   frames). The cache is what keeps slot identities stable session-long.
4. Finalized frames are immutable. Tentative predictions cover the 7-frame
   right-context region and are overwritten every call — usable for live UI
   only, never for cut decisions.
5. Coverage lag: frame `f` at position `p` of its block (`p ∈ 0…5`)
   finalizes once samples through `(f − p + 13) · 1280` are fed. Per-frame
   lag is a sawtooth of **8–13 frames (0.64–1.04 s)**; worst case
   13 frames = 1.04 s.
6. Frame indices are session-local (restart at 0 after `reset()` / a new
   instance).

Latency is measured in **audio timestamps** (samples fed), never wall
clock. Inference time does not appear anywhere in the design; it only
delays when decisions are computed, not what they are.

---

## 2. Global grid and constants

The **80 ms Sortformer frame is the master grid**. Everything downstream —
VAD verdicts, speaker labels, cut points — is expressed on it. Frame `f`
covers samples `[f·1280, (f+1)·1280)`, session-local.

| Constant | Value | Meaning |
|---|---|---|
| `SAMPLE_RATE` | 16 000 Hz | pipeline sample rate (mono Float32) |
| `FRAME_SAMPLES` | 1 280 (80 ms) | one grid frame |
| `VAD_CHUNK_SAMPLES` | 4 096 (256 ms) | one Silero VAD chunk |
| `VAD_FRAME_LATENCY` | 4 frames (0.32 s) | wrapped VAD worst-case latency (§3.1) |
| `SORT_FRAME_LATENCY` | 13 frames (1.04 s) | wrapped Sortformer worst-case latency (§3.2) |
| `PIPELINE_LATENCY_FRAMES` | 13 (1.04 s) | uniform release latency of the aligned stream = max of the above |

---

## 3. Wrapped per-frame models

Both models are wrapped so that, from the outside, each is simply:

> a box that consumes the audio stream and answers, for every 80 ms frame
> `f`, one immutable result — available no later than a fixed number of
> frames after `f` was captured.

**Latency convention (used for every bound below):** a wrapper has
latency `L` frames iff its result for frame `f` is guaranteed available
once `samplesFed ≥ (f + L) · 1280` — i.e. measured from the frame's
*start*. This is the same quantity the release clock (§4.1) compares
against.

Everything chunk- or burst-shaped is private to its wrapper. The aligned
pipeline (§4) reasons only about the two black boxes.

### 3.1 Wrapped VAD: 80 ms verdicts from 256 ms chunks

The wrapper feeds the raw stream to `VadManager` in contiguous 4096-sample
chunks and converts chunk verdicts to frame verdicts by the **midpoint
rule** — a frame's verdict is the verdict of the chunk containing the
frame's midpoint:

```
chunkOf(f)   = floor((f·1280 + 640) / 4096)
vadActive(f) = probability(chunkOf(f)) ≥ threshold
```

The two grids share no common edge except every
`lcm(4096, 1280) = 20 480` samples, so the mapping is periodic with
**period 1.28 s = 16 frames = 5 chunks**, assigning 3-3-4-3-3 frames to
successive chunks:

```
samples:  0        4096      8192       12288      16384      20480
chunks:   |── c0 ───|── c1 ───|─── c2 ────|── c3 ────|── c4 ───|  (repeats)
frames:   |f0|f1|f2|f3|f4|f5|f6|f7|f8|f9|f10|f11|f12|f13|f14|f15|
mapping:   c0 c0 c0 c1 c1 c1 c2 c2 c2 c2  c3  c3  c3  c4  c4  c4
            └─ 3 ─┘ └─ 3 ─┘ └─── 4 ────┘ └── 3 ───┘ └── 3 ───┘
```

**Latency:** frame `f`'s verdict is ready when its chunk completes, i.e.
when `samplesFed ≥ (chunkOf(f)+1)·4096`. The worst case over the 16-frame
period is f6 (+16k): ready at `9.6·1280` samples = **3.6 frames after the
frame's start** (equivalently 2.6 frames after its end; frames 9, 12, 15
are ready before they even finish). Smallest integer bound under the §3
convention:

> **Wrapped VAD = per-frame verdict with latency ≤ 4 frames (320 ms).**

Note the verdict's underlying resolution stays 256 ms — a silence-length
rule stated in frames carries ~256 ms of edge quantization on top (§5).

### 3.2 Wrapped Sortformer: hiding the bursts

Sortformer is already frame-native; the wrapper only hides the 6-frame
burst arrival behind a holding queue. From §1, frame `f` finalizes at
worst when `samplesFed ≥ (f + 13)·1280` (first frame of a block; later
block positions finalize relatively earlier and simply wait in the queue).
Black-box bound:

> **Wrapped Sortformer = per-frame speaker probabilities `[4]` with
> latency ≤ 13 frames (1.04 s).**

### 3.3 Why the wrappers never miss

Both bounds are exact arithmetic consequences of §1 — no tuning, no
runtime assumptions. In particular the wrapped VAD (≤ 4 frames, worst
case 3.6) is always strictly ahead of the wrapped Sortformer
(≤ 13 frames), by ≥ 9.4 frames.

---

## 4. The aligned pipeline

With the wrappers in place, the whole front end is three boxes with known
frame latencies, joined by one clock:

```
                 ┌──────────────────────────────┐
 PCM ───────────►│ Wrapped VAD        (≤ 4 fr)  │──► vadActive(f)
        │        └──────────────────────────────┘        │
        │        ┌──────────────────────────────┐        ▼
        ├───────►│ Wrapped Sortformer (≤ 13 fr) │──► speakerProbs(f)[4]
        │        └──────────────────────────────┘        │
        │        ┌──────────────────────────────┐        ▼
        └───────►│ Raw PCM ring       (§5.1)    │──► sliced at flushes
                 └──────────────────────────────┘
                release clock: emit frame f when samplesFed ≥ (f+13)·1280
                ─────────────── one joint record per 80 ms ───────────────
                            { f, vadActive, speakerProbs[4] }
```

### 4.1 Release clock

> **Release rule:** emit the joint record for frame `f` when
> `samplesFed ≥ (f + PIPELINE_LATENCY_FRAMES) · 1280`.

`PIPELINE_LATENCY_FRAMES = max(VAD_FRAME_LATENCY, SORT_FRAME_LATENCY) =
13`. By §3's bounds, both lookups are guaranteed hits at release time:
Sortformer meets the tick exactly in the worst case; VAD is ≥ 9.4 frames
early. The output is **one record per 80 ms of input at a constant
13-frame (1.04 s) latency** — the burstiness and chunking of §1 are fully
absorbed by the wrappers.

Deliberate consequences:

1. **Worst-case latency is paid uniformly.** Five of six Sortformer frames
   (and every VAD verdict) are available earlier and are intentionally held
   back. Records land exactly 1.04 s behind live audio; the cut/flush
   decisions of §5 add a few frames on top. (Ring retention is *not*
   bounded by this latency — it is governed by §5.1's eviction floor,
   `flushedUpTo`; see §5.6 for its growth behavior.) Nothing user-visible
   cares — cues appear when transcription returns anyway.
2. **Full determinism.** The cut engine is a pure function of the record
   stream: same samples ⇒ byte-identical cuts. Tests can synthesize
   `{vadActive, speaker}` streams and exercise the whole engine with no
   models loaded.

### 4.2 Event loop

```
on pcmBatch(samples):                  # from mixer, ~10 ms batches
    ring.append(samples)
    webmWriter.append(samples)
    samplesFed += samples.count
    wrappedVad.feed(samples)           # runs a chunk per completed 4096
    wrappedSort.feed(samples)          # addAudio + process, per burst
    while (nextFrame + 13) · 1280 ≤ samplesFed:
        emit { f: nextFrame,
               vadActive: wrappedVad.lookup(nextFrame),    # guaranteed hit
               speaker:   wrappedSort.lookup(nextFrame) }  # guaranteed hit
        nextFrame += 1                 # → cut logic (§5)
```

Single-writer: everything after capture runs on one pipeline actor, in
order. There are no cross-thread races by construction.

---

## 5. Cuts and flushes

The record stream (§4) drives two buffers between the aligned frontier and
the transcription API:

```
frame records ──► [ processing buffer ] ──cut──► [ staging buffer ] ──flush──► API
  (from §4)         cut decisions live here        no size limit        one upload
```

- **Cut** — move audio up to a cut point from processing → staging.
  Cheap bookkeeping; happens freely.
- **Flush** — ship the staging buffer as **one upload**. The semantic
  operation; every flush boundary is a transcript segment boundary.

### 5.1 Data model

Both buffers are just pointers into the frame timeline — `flushedUpTo`
and `cutUpTo`, with `frontier` owned by §4's release clock; PCM lives in
the ring. No audio is ever copied until upload encoding.

```
frames:  0 ──────── flushedUpTo ─────────── cutUpTo ─────────── frontier
         │◄─ uploaded ─►│◄──── staging ────►│◄─── processing ───►│
```

- `cut(c)`: `cutUpTo = c` (requires `cutUpTo < c ≤ frontier`).
- `flush()`: upload PCM `[flushedUpTo·1280, cutUpTo·1280)`;
  `flushedUpTo = cutUpTo`. No-op if staging is empty.
- Invariant: `flushedUpTo ≤ cutUpTo ≤ frontier`.
- Ring eviction floor = `flushedUpTo · 1280`.

**Tiling invariant:** uploads partition `[0, flushedUpTo)` — every sample
is uploaded exactly once, in order, silences included. Nothing is ever
discarded.

### 5.2 Constants

| Constant | Value | Seconds | Used by |
|---|---|---|---|
| `ACTIVE_PROB` | 0.5 | — | slot active iff `p ≥ ACTIVE_PROB` (§5.3) |
| `SILENCE_CUT_FRAMES` | 3 | 0.24 | R1 silence cut |
| `LONG_SILENCE_FLUSH_FRAMES` | 25 | 2.00 | R3 long-silence flush |
| `STAGING_FLUSH_FRAMES` | 125 | 10.00 | R2 size flush |
| `SPEAKER_STABLE_FRAMES` | 3 | 0.24 | R4 trigger debounce |
| `SORT_LAG_TOLERANCE_FRAMES` | 3 | 0.24 | R4 branch test |

### 5.3 Per-record state

Processed once per released record, in frame order:

- `silenceRun` — length of the current run of `vadActive == false`
  records (0 while speech).
- `dominant(f)` — a slot is **active** at `f` iff
  `speakerProbs(f)[s] ≥ ACTIVE_PROB`; `dominant(f)` = argmax over active
  slots (tie → lowest slot index), **undefined** when no slot is active.
  Deliberately VAD-independent: speaker-change geometry (`lastStop`,
  `newStart`) comes from Sortformer alone.
- `domRun` — length of the current run of consecutive records with the
  same *defined* dominant speaker; a record with undefined dominant
  resets it to 0.
- `currentSpeaker` — the speaker of the audio currently accumulating
  (staging + processing). Initially unset; the first time a defined
  dominant holds for `SPEAKER_STABLE_FRAMES` records it is set to that
  speaker **with no cut and no flush** (initialization path — R4 handles
  only later changes). Afterwards updated only by R4.

Rules are evaluated per record in the fixed order R1 → R3 → R4; R2 runs
inside every cut. R1/R3 trigger on VAD-silence records and R4 on records
with a defined dominant — and since Sortformer can hear a speaker where
VAD hears silence, R1 and R4 *can* fire on the same record. The fixed
order makes that deterministic: R4's branch test runs after the R1 cut is
applied, which is exactly the state it expects to see.

### 5.4 Rules (normative)

**R1 — silence cut.** Edge-triggered, once per silence run, and only for
a run **preceded by a speech record** — the rule is "speech → 0.24 s of
silence", so a run starting at frame 0 (leading silence) never cuts.
(A maximal silence run is otherwise always preceded by speech; the guard
only excludes session start, and with it a silence-only upload before
anyone has spoken is impossible.) When `silenceRun` reaches
`SILENCE_CUT_FRAMES` (i.e. at the 3rd consecutive silent record `f`):
`cut(f + 1)`. The staged audio keeps its 0.24 s
trailing silence. Because the underlying VAD verdict has 256 ms
resolution, the real silence elapsed when the cut fires is ~0.24–0.5 s
depending on where speech ended inside a chunk — accepted.

**R2 — size flush.** Immediately after any cut: if
`cutUpTo − flushedUpTo > STAGING_FLUSH_FRAMES`, `flush()`. The check runs
*after* the cut's audio is added, so uploads may exceed 10 s by the length
of the final cut.

**R3 — long-silence flush.** Edge-triggered, once per silence run: when
`silenceRun` reaches `LONG_SILENCE_FLUSH_FRAMES`: `flush()`. The silence
itself is **not** cut — it stays in the processing buffer and is swept
into the next upload (tiling invariant). The flush exists so the staged
speech reaches the transcript promptly during the pause, not to remove
silence.

**R4 — speaker change.** *Trigger:* a record whose dominant is defined
and `≠ currentSpeaker` (which must already be set), and whose `domRun`
reaches `SPEAKER_STABLE_FRAMES` — i.e. the new speaker has held
Sortformer dominance for 3 consecutive records, regardless of what VAD
says. A shorter excursion (Sortformer flicker) never triggers and is
simply absorbed into the current turn's audio.

The debounce delays only *when* the rule runs, never the frames it
computes with — all quantities below are original frame numbers, so the
result is identical to an instant decision:

```
newStart = first record of the stable new-speaker run
lastStop = last record where dominant == currentSpeaker  (lastStop < newStart)

if lastStop − SORT_LAG_TOLERANCE_FRAMES < cutUpTo:
    # the boundary was already cut (an R1 silence cut beat Sortformer,
    # which reports offsets slightly late — hence the 3-frame tolerance)
    flush()
else:
    # direct switch or overlap: no VAD silence separated the speakers
    cut( floor((lastStop + 1 + newStart) / 2) )  # midpoint of the gap;
    flush()                                      # degenerates to the boundary
                                                 # when newStart = lastStop+1
currentSpeaker = dominant
```

Both branches end with staging empty and the new speaker's audio
accumulating in processing. Consistency with R1 is structural: if the
inter-speaker pause was ≥ 3 frames, the R1 cut fired at or before
`newStart`, so the branch test lands on `flush()`; anything cut during
the debounce window is likewise seen by the test at decision time.

**Stop.** On session stop: `cut(realFrameEnd)` then `flush()` (details
belong to the future stop/resume section).

### 5.5 Properties

1. **Uploads tile the timeline.** Every sample reaches the API exactly
   once, in order — pauses, gaps and all. Timestamps can never drift and
   no coverage bookkeeping exists.
2. **Each upload is single-speaker** (modulo sub-3-frame flicker): R4
   flushes before `currentSpeaker` ever changes, and R2/R3 flushes happen
   within a turn. The upload's speaker label is `currentSpeaker` at flush
   time.
3. **VAD flicker is harmless.** A spurious silence detection only inserts
   a cut — a boundary inside staging — never a spurious upload. No VAD
   debouncing machinery is needed.
4. **Determinism.** Cuts and flushes are a pure function of the record
   stream; tests can synthesize `{vadActive, speaker}` streams and assert
   byte-identical decisions with no models loaded.

Decision latency: an R1 cut is decided at the release of the 3rd silent
record — silence-start `+ 2 + 13` frames, i.e. **15 frames (1.20 s)**
after speech ends. An R4 flush is likewise decided 15 frames after
`newStart` (2 debounce frames + release latency). Accepted.

### 5.6 Accepted behaviors (deliberate, not bugs)

- **Unbroken monologue uploads late.** A speaker who never pauses ≥ 0.24 s
  produces no cuts, so nothing uploads until their first pause — however
  long that takes. Memory grows with unflushed audio (Float32 mono 16 kHz
  ≈ 3.8 MB/min); accepted.
- **Long silence rides along.** After an R3 flush, continuing silence
  accumulates in processing and is swept into the next upload — even
  minutes of it. The transcription API handles silent audio fine;
  accepted. Consequently there are no `NOTE gap` entries in this design —
  the timeline has no uncovered spans.

---

## 6. Not yet specified (open decisions)

Everything downstream of the flush — upload pipeline, outbox and VTT
format, stop/resume, crash recovery — is to be rewritten on top of this
model. Remaining open decisions:

1. ~~VAD threshold / hysteresis values~~ — resolved in implementation:
   `vadActive = probability ≥ 0.85` (the Silero library default), no
   hysteresis; R1's 3-record requirement is the debounce.
2. Upload/transcript plumbing: whether the previous design's ordered
   outbox, cue indexing, and VTT emission carry over unchanged.
   (Current implementation carries them over; `NOTE gap` and
   `NOTE continuation` are no longer emitted.)
