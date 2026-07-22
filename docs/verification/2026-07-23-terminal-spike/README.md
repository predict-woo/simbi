# M8 spike — embedded Ghostty terminal running packaged codex

Direction under test: instead of the custom chat UI wrapped around
`codex app-server` (~1,600 LOC across CodexKit/SimbiUI), embed a real
terminal in the app and run the ChatGPT app's packaged codex TUI in it.
Codex then owns the whole conversational surface — composer, streaming,
approvals, model switching — and Simbi only hosts the window.

## Verdict: feasible, proven end to end

- `Packages/SimbiKit/Sources/simbi-terminal-spike/main.swift` opens an
  AppKit window hosting a `GhosttyTerminal.TerminalView` (`.exec`
  backend) whose ghostty config sets
  `command = /Applications/ChatGPT.app/Contents/Resources/codex`, with
  `CODEX_HOME=~/.codex` (same gotcha as the app-server integration).
- `02-codex-tui.png` — the codex TUI (v0.145.0-alpha.30) fully rendered
  inside the embedded surface: banner, model line (`gpt-5.6-sol`),
  directory, permissions mode, usage note, composer.
- `03-typed-input.png` — synthesized keystrokes ("hello from inside
  Simbi") appear in the codex composer; the input path
  (NSTextInputClient → ghostty surface → PTY) works. Enter was never
  pressed, so no turn was consumed.

Run by hand: `swift run simbi-terminal-spike` (from Packages/SimbiKit).

## Load-bearing facts

- libghostty-spm 1.3.2 (MIT, prebuilt XCFramework, macOS 13+, actively
  maintained) provides the terminal view, Metal rendering, IME/key
  handling, and spawns/manages the PTY itself in `.exec` mode.
- The wrapper does not expose `ghostty_surface_config_s.command`
  per-surface; the command is set at the controller level via
  `TerminalConfiguration { $0.withCustom("command", path) }`. One
  controller per command is the pattern (surfaces sharing a controller
  share its config).
- The packaged codex binary is the full CLI: `resume`, `--cd`,
  `app-server`, etc. — so per-note sessions can use
  `codex resume <id>` / working-directory args later.
- The TUI inherits the user's `~/.codex` config verbatim — including
  approval mode (this machine showed "YOLO mode"). If Simbi wants
  different defaults it must pass CLI flags (e.g. explicit
  `--sandbox`/approval args) rather than assume the config.

## Open questions for real integration

- Replace the chat window or add the terminal alongside it?
- Per-note terminal (working dir = note folder, `codex resume` with the
  persisted thread id) vs one global terminal.
- The existing thread ids in `state.json` came from app-server threads;
  confirm `codex resume` accepts them.
- Window chrome/theming (GhosttyTheme has 485 themes; match Simbi).
