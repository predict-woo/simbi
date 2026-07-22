# Terminal Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the custom chat UI (SwiftUI transcript + app-server JSON-RPC) with an embedded Ghostty terminal running the ChatGPT app's packaged codex TUI per note.

**Architecture:** A pure `TerminalChatLaunch` value in CodexKit builds a constant shell command plus per-note environment variables (env indirection avoids all quoting); note context is injected via `-c developer_instructions="$SIMBI_CHAT_CONTEXT"` (verified working against the packaged binary). SimbiUI's `ChatWindow` keeps its type name and `windowId` (so the app shell and NoteView are untouched) but hosts a `GhosttyTerminal.TerminalSurfaceView` instead of the transcript/composer. The now-dead chat stack (ChatSession/ChatEvents/ChatTranscript/ChatContextPrompt/MarkdownSegmenter + chat views + M7 spike) is deleted; AppServerClient stays for fixer/converter/transcription.

**Tech Stack:** libghostty-spm 1.3.2 (GhosttyTerminal, exec backend), packaged codex CLI ≥0.145, Swift 6 / SwiftUI, macOS 14.

## Global Constraints

- macOS deployment target 14.0; swift-tools-version 6.0 (Package.swift).
- Pin libghostty-spm `exact: "1.3.2"` (repo convention: fast-moving deps pin exactly).
- `CODEX_HOME` must be `~/.codex` (CodexInstallation gotcha #1) or the ChatGPT app login is invisible.
- Sandbox/approval parity with the old chat: `-s workspace-write -a on-request`, home root additionally writable (`--add-dir`).
- App Sandbox stays OFF (project.yml) — required to spawn codex.
- No AGENTS.md or any file written into note folders.
- Evidence screenshots land in `docs/verification/2026-07-23-terminal-chat/`.

---

### Task 1: `TerminalChatLaunch` (CodexKit, pure + tested)

**Files:**
- Create: `Packages/SimbiKit/Sources/CodexKit/TerminalChatLaunch.swift`
- Test: `Packages/SimbiKit/Tests/CodexKitTests/TerminalChatLaunchTests.swift`

**Interfaces:**
- Consumes: `CodexInstallation` (binaryURL, codexHomeURL), `CodexChat.notePath(noteFolderURL:homeRootURL:)`.
- Produces: `public struct TerminalChatLaunch { public static let commandLine: String; public let envVars: [String: String]; public static func forNote(noteFolderURL: URL, homeRootURL: URL, installation: CodexInstallation) -> TerminalChatLaunch; static func developerInstructions(noteFolderURL: URL, homeRootURL: URL) -> String }`

- [ ] Write failing tests: `commandLine` references every env var and the parity flags; `envVars` carries CODEX_HOME/bin/note dir/home root/context; `developerInstructions` names only files that exist (note.md, transcript.vtt, context/*.md, files/*) using tmp-dir fixtures and mentions the note path.
- [ ] `swift test --filter TerminalChatLaunchTests` → FAIL (type missing).
- [ ] Implement. Command line (constant — all per-note variability rides in env):
  `exec "$SIMBI_CODEX_BIN" -C "$SIMBI_NOTE_DIR" --add-dir "$SIMBI_HOME_ROOT" -s workspace-write -a on-request -c developer_instructions="$SIMBI_CHAT_CONTEXT"`
  (`-c` values that fail TOML parsing are used as literal strings — codex --help — so no TOML escaping is needed.)
  `developerInstructions` describes the folder (note.md = the note, transcript.vtt = recording transcript, context/ = converted attachments, files/ = original attachments), lists the file names present, and says to read what's relevant and edit on disk.
- [ ] `swift test --filter TerminalChatLaunchTests` → PASS.
- [ ] Commit `feat: TerminalChatLaunch builds codex TUI launch spec per note`.

### Task 2: ChatWindow hosts the terminal (SimbiUI)

**Files:**
- Rewrite: `Packages/SimbiKit/Sources/SimbiUI/ChatView.swift` → delete; Create: `Packages/SimbiKit/Sources/SimbiUI/TerminalChatWindow.swift` (keeps `public struct ChatWindow`, `windowId = "note-chat"`)
- Modify: `Packages/SimbiKit/Package.swift` (SimbiUI deps += `GhosttyTerminal`)

**Interfaces:**
- Consumes: `TerminalChatLaunch.forNote(...)`, `GhosttyTerminal` (`TerminalViewState`, `TerminalSurfaceView`, `TerminalSurfaceOptions`, `TerminalController`, `TerminalConfiguration`).
- Produces: `ChatWindow(noteFolderURL:)` — unchanged signature for App/SimbiApp.swift and NoteView.

- [ ] Shared `TerminalChatServices.controller` (one ghostty app; command comes from `TerminalChatLaunch.commandLine` via `TerminalConfiguration { $0.withCustom("command", …) }`).
- [ ] Per-window `TerminalViewState(controller: shared)` with `TerminalSurfaceOptions(backend: .exec, workingDirectory: noteDir, envVars: launch.envVars)`; `.terminalFocusOnAppear`; degraded banner when `CodexInstallation.standard.isBinaryInstalled` is false (same copy as before); session-ended overlay with Restart button (bump a generation counter → fresh `TerminalViewState`).
- [ ] `swift build` (SimbiUI) → succeeds.
- [ ] Commit `feat: chat window hosts embedded codex terminal`.

### Task 3: Delete the dead chat stack

**Files:**
- Delete: CodexKit `ChatSession.swift`, `ChatEvents.swift`, `ChatTranscript.swift`, `ChatContextPrompt.swift`, `MarkdownSegmenter.swift`; SimbiUI `ChatModel.swift`, `ChatRows.swift`, `ChatMarkdownView.swift`; `Sources/simbi-chat-spike/` (+ its Package.swift target)
- Delete tests: `ChatSessionTests.swift`, `ChatEventsTests.swift`, `ChatTranscriptTests.swift`, `ChatContextPromptTests.swift`, `MarkdownSegmenterTests.swift`
- Modify: `Packages/SimbiKit/Sources/SimbiUI/SettingsView.swift` (drop "Chat threads" picker), `Packages/SimbiKit/Sources/SimbiKit/Settings.swift` (drop `chatModel` field; decode stays tolerant of old files)
- Keep: `AppServerClient`, `JSONRPCMessage`, `CodexChat`/`CodexModels` (fixer/converter pickers), `CodexInstallation`.

- [ ] Delete, fix references, `swift build && swift test` → all green.
- [ ] Commit `refactor: remove app-server chat stack superseded by terminal chat`.

### Task 4: Verify in the real app + PR

- [ ] `xcodegen generate` + build the Simbi app; kill any stale instance first (memory rule), launch fresh.
- [ ] Open a note → Chat → screenshot codex TUI running in the note folder; send one real turn ("What files does this note contain?") → screenshot the answer. Save both + README to `docs/verification/2026-07-23-terminal-chat/`.
- [ ] Commit evidence; push branch; `gh pr create` against `predict-woo/simbi` main with summary, risks (alpha binary, `developer_instructions` config key, young package), and follow-ups (per-note `codex resume`, theming).
