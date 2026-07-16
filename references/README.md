# References

Read-only research material backing SPEC.md and docs/recording-algorithm.md.

- `codex-transcription/` — verified proof that the ChatGPT `backend-api/transcribe`
  endpoint accepts WebM/Opus uploads with Codex Desktop credentials/headers.
- `codex-open/` — verified notes on the `codex app-server` JSON-RPC protocol and
  `codex://` deeplinks (thread creation, naming, CODEX_HOME gotchas).
- `FluidAudio/` — **not committed.** A full checkout used to verify the Sortformer
  API facts in docs/recording-algorithm.md §0. Fetch with:

  ```bash
  git clone https://github.com/FluidInference/FluidAudio references/FluidAudio
  ```
