# M4 fixer-thread verification — 2026-07-16

`swift run --package-path Packages/SimbiKit simbi-fixer-spike` — a REAL
end-to-end run: TranscriptFixer drove the real `codex app-server`
(thread/start with workspace-write sandbox scoped to the note folder,
instruction turn, coalesced cue pings, archive at stop) against a
transcript seeded with genuine ASR-style errors and speaker
self-introductions.

```
PASS invariants: 3 cues, indices and timestamps untouched, valid WebVTT
PASS spelling: Simbi corrected in all cues
PASS speakers: Alice Kim unified across sessions; Bob Park renamed
OVERALL: PASS
```

The fixer corrected "Symbi" / "simby" / "sim bee" → "Simbi" (using note.md
as ground truth), fixed "grate" → "great", renamed `<v Speaker 1>` →
`<v Alice Kim>` and `<v Speaker 2>` → `<v Bob Park>` from their
self-introductions, and unified Alice across the session 1/2 boundary —
all without touching cue indices, timestamps, or NOTE blocks
(`fixed-transcript.vtt`). The thread appears in the ChatGPT app as
"[simbi] fixer: …" and is archived after the final ping drains.

## Bug found and fixed during verification

`FileHandle.read(upToCount:)` inside a detached Task never delivered the
child process's stdout on this Foundation version — the client hung at
`initialize` with the response pipe empty. Fix: the M1-spike-proven
transport (dedicated thread reading `availableData`, bridged into the
actor via AsyncStream).
