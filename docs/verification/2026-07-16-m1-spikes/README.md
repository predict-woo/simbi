# M1 spike verification — 2026-07-16

Both SPEC.md §8 M1 spikes ran against the real externals and passed.

## (a) Opus/WebM encode + decode (`simbi-audio-spike`)

`swift run --package-path Packages/SimbiKit simbi-audio-spike`:

```
PASS synthesize: 74752 samples (4.67 s)
PASS encode: 2 sessions, 4680 ms, 2 clusters, 13504 bytes (23.1 kbps), decode round-trip 74880 samples
PASS upload: HTTP 200
transcription:  Symbi is a note-taking app. It records meetings, and it transcribes them.
PASS verify: transcription contains ["note", "meetings"]
OVERALL: PASS
```

- The uploaded file was a **two-session live-mode append** (create → close →
  cluster-scan offset → append), i.e. exactly what stop/resume produces —
  and `backend-api/transcribe` accepted it and transcribed it correctly.
- Bitrate landed at 23.1 kbps (target ~24 kbps VBR).
- Package tests additionally cover: create/append/decode round-trip,
  cluster index + seek, mid-recording parseability after `flush()` (crash
  tolerance), OpusHead layout (`OpusWebMTests`).

### Gotcha worth remembering

`mkvmuxer::Cluster::AddFrame(data, …, abs_timecode, …)` documents the
timestamp as "timecode units" but actually requires **nanoseconds**
(`WriteFrame` divides by the timecode scale). Passing ms silently writes
timecode 0 for every block in the first cluster and hard-fails on the
first cluster that doesn't start at 0.

## (b) codex app-server round-trip (`Spikes/AppServerSpike`)

`swift run --package-path Spikes/AppServerSpike appserver-spike`: all steps
PASS (initialize → thread/start → thread/name/set → turn/start →
turn/completed with reply "pong" → thread/archive → thread/unarchive →
thread/resume). Full wire shapes and gotchas in
`Spikes/AppServerSpike/README.md`. Key findings for CodexKit:

- **Archived threads refuse `thread/resume`** (-32600); the path is
  `thread/unarchive` first, then resume.
- `turn/start` accepts `approvalPolicy: "never"` and a tagged
  `sandboxPolicy` object (`{"type":"readOnly", …}`), while `thread/start`'s
  `sandbox` is a plain string — the two are not symmetric.
- The user's global `~/.codex` config rides along on every turn (plugin
  hooks + MCP servers ≈ 18k input tokens even for a one-word turn);
  CodexKit should consider per-thread config overrides and must tolerate
  hook/MCP notification noise.
- Responses and notifications interleave freely; the client needs a real
  demux loop keyed on request id.
