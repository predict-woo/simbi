#!/usr/bin/env python3
"""Simulation and invariant checker for docs/recording-algorithm.md (v2).

Simulates the REAL mechanics, not the abstraction:
  - PCM arrives in small batches (10 ms by default; batch size must not matter).
  - VAD verdicts materialize only when a 4096-sample chunk completes (§1).
  - Sortformer frames finalize only in 6-frame blocks, block k available once
    samplesFed >= (6k+13)*1280 (§1).
  - The release clock (§4.1) is the only reader; every lookup HARD-ASSERTS the
    result is available, so §3's latency bounds are verified by construction.

Model imperfections are synthesized realistically:
  - Sortformer: per-interval onset/offset lag (it reacts slower than VAD — the
    premise behind SORT_LAG_TOLERANCE_FRAMES), probability jitter near 0.5 at
    boundaries, rare 1-2 frame dominant flicker / dropout.
  - VAD: chunk-fraction quantization + hangover; reacts fast (acoustic).

Test tiers:
  1. Named scenarios covering every threshold's boundary cases.
  2. Randomized realistic fuzzing (default 200 seeds).
  3. Adversarial fuzzing: arbitrary record streams straight into the engine
     (default 200 seeds) — structural invariants must survive ANY input.

Hard invariants checked (H1..H9):
  H1 pointers: flushedUpTo <= cutUpTo <= frontier at every step (§5.1)
  H2 cut precondition: cutUpTo < c <= frontier for every cut (§5.1)
  H3 tiling: uploads exactly partition [0, realFrameEnd), in order (§5.1/§5.5)
  H4 wrapper availability: VAD chunk + Sortformer block ready at release (§3)
  H5 R1 fires once per silence run, only when preceded by speech (§5.4)
  H6 staging never exceeds STAGING_FLUSH_FRAMES before a cut (R2 works) (§5.4)
  H7 batch-size invariance: identical uploads for any batching of same audio
  H8 determinism: identical uploads on re-run
  H9 speaker purity: no stable (>= SPEAKER_STABLE_FRAMES) foreign dominant run
     buried in an upload's interior (ends >= 3 frames before the upload ends);
     boundary-crossing runs are the documented smear allowance (§5.5)

Run:  python3 docs/recording-algorithm-sim.py [--fuzz N] [--adversarial N]
Exit code 0 = all invariants hold.
"""

import argparse
import random
import sys
from dataclasses import dataclass

# --- Constants (§2, §5.2) --------------------------------------------------
SAMPLE_RATE = 16000
FRAME = 1280                      # 80 ms
CHUNK = 4096                      # 256 ms VAD chunk
PIPELINE_LATENCY_FRAMES = 13      # release clock (§4.1)
ACTIVE_PROB = 0.5
SILENCE_CUT_FRAMES = 3
LONG_SILENCE_FLUSH_FRAMES = 25
STAGING_FLUSH_FRAMES = 125
SPEAKER_STABLE_FRAMES = 3
SORT_LAG_TOLERANCE_FRAMES = 3
NUM_SPK = 4
ALIGN = 20480                     # lcm(FRAME, CHUNK): pad sessions to this


class InvariantError(AssertionError):
    pass


@dataclass
class Upload:
    start: int          # frame index, inclusive
    end: int            # frame index, exclusive
    speaker: object     # slot int, or None if never initialized
    reason: str         # rule that triggered the flush


# --- The engine: a literal transcription of §5 ------------------------------
class Engine:
    def __init__(self):
        self.flushed = 0            # flushedUpTo
        self.cut_up_to = 0          # cutUpTo
        self.frontier = 0           # end of released records (owned by §4)
        self.silence_run = 0
        self.silence_run_start = None
        self.dom_prev = None
        self.dom_run = 0
        self.dom_run_start = None
        self.last_dom_frame = {}    # slot -> last frame it was dominant
        self.current_speaker = None
        self.uploads = []
        self.r1_fires = []          # (run_start, fire_frame) for H5

    # §5.1 cut(c). H2 + H6 checked here.
    def cut(self, c, reason):
        if not (self.cut_up_to < c <= self.frontier):
            raise InvariantError(
                f"H2 cut precondition: cutUpTo={self.cut_up_to} c={c} "
                f"frontier={self.frontier} reason={reason}")
        if self.cut_up_to - self.flushed > STAGING_FLUSH_FRAMES:
            raise InvariantError(
                f"H6 staging exceeded {STAGING_FLUSH_FRAMES} before a cut: "
                f"{self.cut_up_to - self.flushed}")
        self.cut_up_to = c
        # R2 — size flush, checked immediately after every cut (§5.4).
        if self.cut_up_to - self.flushed > STAGING_FLUSH_FRAMES:
            self.flush("R2")

    # §5.1 flush(). No-op when staging is empty.
    def flush(self, reason):
        if self.cut_up_to == self.flushed:
            return
        self.uploads.append(
            Upload(self.flushed, self.cut_up_to, self.current_speaker, reason))
        self.flushed = self.cut_up_to

    # §5.3/§5.4: one released record. silence_run/dom_run advance by exactly
    # one per record, so the edge triggers below use `==` (a run can never
    # jump past its threshold — unlike the old burst-driven design).
    def push(self, f, vad_active, probs):
        assert f == self.frontier, "records must be released in order"
        self.frontier = f + 1

        # dominant(f): active slots, argmax, tie -> lowest slot (§5.3)
        active = [s for s in range(NUM_SPK) if probs[s] >= ACTIVE_PROB]
        dominant = None
        if active:
            best = max(probs[s] for s in active)
            dominant = min(s for s in active if probs[s] == best)

        # silence run tracking
        if not vad_active:
            if self.silence_run == 0:
                self.silence_run_start = f
            self.silence_run += 1
        else:
            self.silence_run = 0

        # R1 — silence cut (guard: run preceded by speech, i.e. start > 0)
        if (not vad_active and self.silence_run == SILENCE_CUT_FRAMES
                and self.silence_run_start > 0):
            self.r1_fires.append((self.silence_run_start, f))
            self.cut(f + 1, "R1")

        # R3 — long-silence flush
        if not vad_active and self.silence_run == LONG_SILENCE_FLUSH_FRAMES:
            self.flush("R3")

        # dominant run tracking (VAD-independent, §5.3)
        if dominant is not None:
            if dominant == self.dom_prev:
                self.dom_run += 1
            else:
                self.dom_run = 1
                self.dom_run_start = f
            self.dom_prev = dominant
        else:
            self.dom_run = 0
            self.dom_prev = None

        # R4 — speaker change (+ the no-cut/no-flush initialization path)
        if dominant is not None and self.dom_run == SPEAKER_STABLE_FRAMES:
            if self.current_speaker is None:
                self.current_speaker = dominant       # init (§5.3)
            elif dominant != self.current_speaker:
                new_start = self.dom_run_start
                last_stop = self.last_dom_frame.get(self.current_speaker)
                assert last_stop is not None and last_stop < new_start
                if last_stop - SORT_LAG_TOLERANCE_FRAMES < self.cut_up_to:
                    self.flush("R4-flush")
                else:
                    self.cut((last_stop + 1 + new_start) // 2, "R4-cut")
                    self.flush("R4-cut")
                self.current_speaker = dominant

        if dominant is not None:
            self.last_dom_frame[dominant] = f

        # H1
        if not (self.flushed <= self.cut_up_to <= self.frontier):
            raise InvariantError(
                f"H1 pointers: {self.flushed} <= {self.cut_up_to} "
                f"<= {self.frontier} violated at f={f}")

    # §5.4 Stop. Harness must have drained all records first.
    def stop(self, real_frame_end):
        assert self.frontier == real_frame_end, "drain before stop"
        if real_frame_end > self.cut_up_to:
            self.cut(real_frame_end, "stop")
        self.flush("stop")


# --- Ground truth and model synthesis --------------------------------------
@dataclass
class Scenario:
    name: str
    intervals: list      # (start_sec, end_sec, speaker) — may overlap
    duration_sec: float
    sort_onset_lag: int = 1     # frames Sortformer is late on onsets
    sort_offset_lag: int = 3    # frames Sortformer is late on offsets
    flicker_p: float = 0.0      # per-frame chance of a 1-2 frame dominant
                                # hijack or dropout
    seed: int = 1


def total_frames(sc):
    n = int(sc.duration_sec * SAMPLE_RATE)
    n = ((n + ALIGN - 1) // ALIGN) * ALIGN     # pad with silence to align
    return n // FRAME, n


def overlap_frac(lo, hi, a, b):
    return max(0.0, min(hi, b) - max(lo, a)) / (hi - lo)


def synth_models(sc):
    """Deterministic model outputs from ground truth. Computed up front so
    batching cannot influence them (the mechanics only gate WHEN they become
    visible) — that is what makes H7 a meaningful test."""
    rng = random.Random(sc.seed)
    frames, samples = total_frames(sc)
    chunks = samples // CHUNK

    # Per-interval Sortformer lag: onset late, offset late (never early).
    lagged = []
    for (a, b, spk) in sc.intervals:
        on = rng.randint(0, sc.sort_onset_lag) * FRAME / SAMPLE_RATE
        off = rng.randint(1, sc.sort_offset_lag) * FRAME / SAMPLE_RATE
        lagged.append((a + on, b + off, spk))

    sort_probs = []
    for f in range(frames):
        lo, hi = f * FRAME / SAMPLE_RATE, (f + 1) * FRAME / SAMPLE_RATE
        p = [0.0] * NUM_SPK
        for (a, b, spk) in lagged:
            cov = overlap_frac(lo, hi, a, b)
            if cov > 0.0:
                # cov 1.0 -> ~0.93, cov 0.5 -> ~0.48: boundary frames sit
                # near ACTIVE_PROB and genuinely flicker (exercises debounce)
                val = 0.9 * cov + rng.uniform(0.0, 0.08)
                p[spk] = max(p[spk], min(0.99, val))
        sort_probs.append(p)

    # Rare flicker: hijack another slot or drop everything for 1-2 frames.
    f = 0
    while f < frames:
        if rng.random() < sc.flicker_p:
            span = rng.randint(1, 2)
            if rng.random() < 0.5:
                bad = rng.randrange(NUM_SPK)
                for g in range(f, min(frames, f + span)):
                    sort_probs[g][bad] = 0.9
            else:
                for g in range(f, min(frames, f + span)):
                    sort_probs[g] = [0.0] * NUM_SPK
            f += span + 1
        else:
            f += 1

    # VAD: acoustic, fast. Chunk verdict from true (unlagged) speech fraction
    # with Silero-style hangover.
    vad = []
    prev = False
    for c in range(chunks):
        lo, hi = c * CHUNK / SAMPLE_RATE, (c + 1) * CHUNK / SAMPLE_RATE
        frac = 0.0
        for (a, b, _) in sc.intervals:
            frac = max(frac, 0.0)
            frac += overlap_frac(lo, hi, a, b)
        frac = min(1.0, frac)
        v = frac >= 0.25 or (prev and frac >= 0.05)
        vad.append(v)
        prev = v
    return sort_probs, vad, frames, samples


# --- Harness: feeds batches, drives the release clock -----------------------
def make_batches(samples, plan, rng=None):
    out, fed = [], 0
    while fed < samples:
        if plan == "random":
            n = rng.randint(80, 2400)
        else:
            n = plan
        n = min(n, samples - fed)
        out.append(n)
        fed += n
    return out


def run_pipeline(sc, batch_plan=160, batch_rng_seed=0):
    sort_probs, vad, frames, samples = synth_models(sc)
    eng = Engine()
    fed = 0
    nxt = 0
    rng = random.Random(batch_rng_seed)
    for n in make_batches(samples, batch_plan, rng):
        fed += n
        # §4.1 release clock
        while (nxt + PIPELINE_LATENCY_FRAMES) * FRAME <= fed:
            f = nxt
            # H4: wrapper availability, from the raw mechanics of §1
            ch = (f * FRAME + FRAME // 2) // CHUNK
            if fed < (ch + 1) * CHUNK:
                raise InvariantError(f"H4 VAD chunk {ch} not ready at f={f}")
            block = f // 6
            if fed < (block * 6 + 13) * FRAME:
                raise InvariantError(f"H4 Sortformer block not ready at f={f}")
            eng.push(f, vad[ch], sort_probs[f])
            nxt += 1
    # Stop: drain records beyond the release clock (models the future stop
    # section's obligation: pad/finalize both models so every real frame gets
    # a record — the doc's "cut(realFrameEnd) then flush" implies this drain).
    while nxt < frames:
        f = nxt
        eng.push(f, vad[(f * FRAME + FRAME // 2) // CHUNK], sort_probs[f])
        nxt += 1
    eng.stop(frames)
    return eng, sort_probs, vad, frames


# --- Post-run validation ----------------------------------------------------
def dominant_of(probs):
    active = [s for s in range(NUM_SPK) if probs[s] >= ACTIVE_PROB]
    if not active:
        return None
    best = max(probs[s] for s in active)
    return min(s for s in active if probs[s] == best)


def validate(eng, sort_probs, frames, name):
    # H3 tiling
    pos = 0
    for u in eng.uploads:
        if u.start != pos or u.end <= u.start:
            raise InvariantError(
                f"H3 tiling broken in {name}: upload {u} at pos {pos}")
        pos = u.end
    if pos != frames:
        raise InvariantError(f"H3 tiling incomplete in {name}: {pos} != {frames}")

    # H5 R1 semantics: one fire per run start, run start > 0
    starts = [s for s, _ in eng.r1_fires]
    if len(starts) != len(set(starts)):
        raise InvariantError(f"H5 R1 fired twice for one silence run in {name}")
    if any(s == 0 for s in starts):
        raise InvariantError(f"H5 R1 fired for leading silence in {name}")

    # H9 purity: stable foreign dominant runs buried in an upload's interior
    dom = [dominant_of(p) for p in sort_probs]
    for u in eng.uploads:
        if u.speaker is None:
            continue
        f = u.start
        while f < u.end:
            d = dom[f]
            if d is None or d == u.speaker:
                f += 1
                continue
            g = f
            while g < u.end and dom[g] == d:
                g += 1
            run_len = g - f
            if (run_len >= SPEAKER_STABLE_FRAMES
                    and g + SPEAKER_STABLE_FRAMES <= u.end
                    and f > u.start):
                raise InvariantError(
                    f"H9 purity: stable run of spk {d} frames [{f},{g}) "
                    f"buried in upload {u} in {name}")
            f = g


def uploads_key(eng):
    return tuple((u.start, u.end, u.speaker) for u in eng.uploads)


# --- Scenarios --------------------------------------------------------------
def named_scenarios():
    S = Scenario
    return [
        # Turn-taking with pauses comfortably above the 0.24 s cut
        S("alternating-pauses", [(0.5, 4.0, 0), (4.6, 7.2, 1), (7.8, 9.6, 0)], 12),
        # Rapid switch, no pause at all (R4 midpoint branch)
        S("rapid-switch", [(0.5, 4.0, 0), (4.0, 7.0, 1), (7.0, 9.0, 2)], 11),
        # Overlapping switch (B starts before A stops)
        S("overlap-switch", [(0.5, 5.0, 0), (4.2, 8.0, 1)], 10),
        # Pause lengths straddling every threshold
        S("pause-sweep", [(0.5, 2.0, 0), (2.15, 3.5, 0), (3.9, 5.0, 0),
                          (7.4, 8.4, 0), (11.5, 12.5, 0)], 15),
        # Monologue with sub-cut breathing pauses only: no upload until stop
        S("monologue", [(0.5, 15.0, 0), (15.15, 30.0, 0), (30.15, 45.0, 0)], 46),
        # Long dead air mid-session (R3, then silence rides along)
        S("long-silence", [(0.5, 3.0, 0), (63.0, 66.0, 0)], 68),
        # Leading silence, then speech; and a silence-only session
        S("leading-silence", [(6.0, 9.0, 0)], 12),
        S("all-silence", [], 8),
        # Speech from the very first sample
        S("speech-at-zero", [(0.0, 3.0, 0), (3.5, 6.0, 1)], 8),
        # Same speaker resumes after a >2 s pause (R1+R3, no R4)
        S("same-speaker-resume", [(0.5, 3.0, 0), (6.5, 9.0, 0)], 11),
        # >10 s of speech with small pauses: R2 size flushes
        S("size-flush", [(0.5, 6.0, 0), (6.4, 12.0, 0), (12.4, 18.0, 0),
                         (18.4, 24.0, 0)], 26),
        # Sortformer very late on offsets (stress the -3 tolerance)
        S("late-sortformer", [(0.5, 4.0, 0), (4.5, 8.0, 1)], 10,
          sort_onset_lag=2, sort_offset_lag=4),
        # Heavy flicker on top of normal turn-taking
        S("flicker", [(0.5, 5.0, 0), (5.5, 10.0, 1), (10.5, 15.0, 2)], 17,
          flicker_p=0.02),
        # Stop lands mid-speech / mid-silence / mid-debounce
        S("stop-mid-speech", [(0.5, 7.9, 0)], 8),
        S("stop-mid-silence", [(0.5, 3.0, 0)], 6),
        S("stop-mid-switch", [(0.5, 5.6, 0), (5.65, 5.95, 1)], 6),
    ]


def random_scenario(seed):
    rng = random.Random(seed)
    t = rng.uniform(0.0, 2.0)
    intervals = []
    spk = rng.randrange(min(NUM_SPK, 3))
    for _ in range(rng.randint(2, 14)):
        dur = rng.uniform(0.3, 9.0)
        intervals.append((t, t + dur, spk))
        r = rng.random()
        if r < 0.25:
            gap = rng.uniform(0.03, 0.35)       # around the R1 threshold
        elif r < 0.55:
            gap = rng.uniform(0.35, 1.9)        # glue-sized pause
        elif r < 0.8:
            gap = rng.uniform(1.9, 8.0)         # around/over R3
        elif r < 0.92:
            gap = rng.uniform(-min(1.0, dur * 0.5), 0.0)   # overlap
        else:
            gap = rng.uniform(8.0, 30.0)        # long dead air
        t = t + dur + gap
        t = max(t, intervals[-1][0] + 0.1)
        if rng.random() < 0.6:
            spk = rng.randrange(NUM_SPK)
    dur_total = max(x[1] for x in intervals) + rng.uniform(0.5, 4.0)
    return Scenario(f"fuzz-{seed}", intervals, dur_total,
                    sort_onset_lag=rng.randint(0, 2),
                    sort_offset_lag=rng.randint(1, 4),
                    flicker_p=rng.choice([0.0, 0.005, 0.02]),
                    seed=seed)


def adversarial_run(seed):
    """Arbitrary record stream straight into the engine: structural
    invariants (H1/H2/H3/H5/H6) must survive ANY input."""
    rng = random.Random(seed)
    frames = rng.randint(1, 1200)
    eng = Engine()
    style = rng.randrange(4)
    vad_p = rng.uniform(0.1, 0.9)
    for f in range(frames):
        if style == 0:      # iid noise
            vad = rng.random() < vad_p
            probs = [rng.random() if rng.random() < 0.3 else 0.0
                     for _ in range(NUM_SPK)]
        elif style == 1:    # alternate every frame
            vad = f % 2 == 0
            probs = [0.0] * NUM_SPK
            probs[f % NUM_SPK] = 0.9
        elif style == 2:    # all speech, dominant random walk
            vad = True
            probs = [0.0] * NUM_SPK
            probs[(f // rng.randint(1, 6)) % NUM_SPK] = 0.9
        else:               # mostly silence with speech bursts
            vad = (f // 7) % 5 == 0
            probs = [0.0] * NUM_SPK
            if vad or rng.random() < 0.2:
                probs[rng.randrange(NUM_SPK)] = 0.9
        eng.push(f, vad, probs)
    eng.stop(frames)
    # structural checks only (purity is meaningless for noise)
    pos = 0
    for u in eng.uploads:
        if u.start != pos or u.end <= u.start:
            raise InvariantError(f"H3 tiling broken in adversarial-{seed}")
        pos = u.end
    if pos != frames:
        raise InvariantError(f"H3 tiling incomplete in adversarial-{seed}")
    starts = [s for s, _ in eng.r1_fires]
    if len(starts) != len(set(starts)) or any(s == 0 for s in starts):
        raise InvariantError(f"H5 broken in adversarial-{seed}")


# --- Main -------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=200)
    ap.add_argument("--adversarial", type=int, default=200)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    failures = 0

    print("== named scenarios ==")
    for sc in named_scenarios():
        try:
            eng, probs, vad, frames = run_pipeline(sc)
            validate(eng, probs, frames, sc.name)
            # H8 determinism
            eng2, _, _, _ = run_pipeline(sc)
            if uploads_key(eng) != uploads_key(eng2):
                raise InvariantError(f"H8 nondeterminism in {sc.name}")
            # H7 batch invariance
            for plan, bseed in [(1280, 0), (4096, 0), (999, 0),
                                ("random", 7), ("random", 8)]:
                eng3, _, _, _ = run_pipeline(sc, plan, bseed)
                if uploads_key(eng) != uploads_key(eng3):
                    raise InvariantError(
                        f"H7 batch-plan {plan}/{bseed} changed uploads "
                        f"in {sc.name}")
            reasons = {}
            for u in eng.uploads:
                reasons[u.reason] = reasons.get(u.reason, 0) + 1
            print(f"  ok  {sc.name:22s} uploads={len(eng.uploads):3d}  {reasons}")
            if args.verbose:
                for u in eng.uploads:
                    print(f"        [{u.start*0.08:8.2f}s {u.end*0.08:8.2f}s) "
                          f"spk={u.speaker} {u.reason}")
        except InvariantError as e:
            failures += 1
            print(f"  FAIL {sc.name}: {e}")

    print(f"== realistic fuzz ({args.fuzz} seeds) ==")
    for seed in range(args.fuzz):
        sc = random_scenario(seed)
        try:
            eng, probs, vad, frames = run_pipeline(sc)
            validate(eng, probs, frames, sc.name)
            eng3, _, _, _ = run_pipeline(sc, "random", seed + 1)
            if uploads_key(eng) != uploads_key(eng3):
                raise InvariantError(f"H7 batching changed uploads in {sc.name}")
        except InvariantError as e:
            failures += 1
            print(f"  FAIL {sc.name}: {e}")
    if failures == 0:
        print("  ok  all seeds")

    print(f"== adversarial fuzz ({args.adversarial} seeds) ==")
    adv_fail = 0
    for seed in range(args.adversarial):
        try:
            adversarial_run(seed)
        except InvariantError as e:
            adv_fail += 1
            failures += 1
            print(f"  FAIL adversarial-{seed}: {e}")
    if adv_fail == 0:
        print("  ok  all seeds")

    print("PASS" if failures == 0 else f"FAILURES: {failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
