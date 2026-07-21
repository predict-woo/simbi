# In-App Codex Chat

**Date:** 2026-07-21
**Status:** Approved

## Problem

"Chat in Codex" (SPEC.md §5.4) deeplinks into the ChatGPT app, and it opens an
empty conversation every time: `CodexChat.startChat` unconditionally calls
`thread/start`, and nothing persists a chat thread id, so the deeplink always
lands on a brand-new thread. Beyond the bug, the deeplink UX itself is weak —
the composer can't be pre-filled and the conversation lives outside Simbi.

## Decision

Build the chat UI inside Simbi, talking to the already-running
`codex app-server` through the existing `AppServerClient`. One persistent chat
thread per note, resumed on every open. The chat lives in a **separate
per-note window** (like `FixerActivityWindow`). The agent runs
**workspace-write with approval prompts** rendered inline in the chat. The
deeplink entry point is **replaced** by the in-app window (threads keep the
same home-root cwd + naming conventions, so they remain browsable in the
ChatGPT app's history).

Research note: no popular maintained macOS-native chat framework fits agent
chat (Exyte Chat is iOS-only; SwiftyChat is messenger-shaped). Popular native
mac AI apps (macai, Enchanted, HuggingChat-macOS) all hand-roll the same three
components — transcript list with bottom-anchored scroll, markdown message
views, composer. We do the same, styled with Simbi's `Design` system,
rendering markdown with the already-shipped `swift-markdown-engine`, and
borrowing app-server event-handling structure from Bikz/codex-chat (MIT).

## 1. CodexKit backend

### AppServerClient: server→client requests

Approvals arrive as JSON-RPC *requests* from the server (both `method` and
`id`), which today would be mis-fanned-out as notifications and never
answered. Add a server-request path to `AppServerClient.receive`:

- A message with `method` **and** `id` routes to a registered async server
  request handler `(method, params Data) async -> [String: any Sendable]?`;
  its return value is written back as `{"id": id, "result": ...}`. If no
  handler claims it, respond with a JSON-RPC error so the server isn't left
  hanging.
- Notifications (`method`, no `id`) keep the existing fan-out. Responses
  (`id`, no `method`) keep the existing demux. Fixer/converter are untouched.

### ChatSession (new actor, one per note)

Owns the note's chat thread lifecycle over `CodexServices.appServer`:

- `ensureThread()` — if `NoteRecordingState.chatThreadId` exists, try
  `thread/resume`; hydrate history from the resume response's
  `thread.turns[].items[]` (shape confirmed by `simbi-chat-spike`). If resume
  fails (deleted/corrupt), fall back to creating fresh. Creation =
  `thread/start` (cwd = home root), `thread/name/set` → `"<note> — chat"`,
  context turn (existing `CodexChat.startChat` logic, refactored in), persist
  the id via `NoteRecordingState.update`.
- `send(text)` — `turn/start` with `SimbiSettings.chatModel`, sandbox
  `workspace-write`, approval policy left at default so approval requests
  flow.
- `interrupt()` — `turn/interrupt` for the active turn.
- `newChat()` — archive the current thread, clear `chatThreadId`, create
  fresh via `ensureThread()`.
- Emits `AsyncStream<ChatEvent>` — parsed, threadId-filtered events:
  `agentMessageDelta(itemId, text)`, `itemStarted/itemCompleted(ChatItem)`,
  `turnStarted/turnCompleted(status)`, `approvalRequest(ApprovalRequest)`.
  `ChatItem` covers: `agentMessage(markdown)`, `userMessage(text)`,
  `reasoning`, `commandExecution(command, status, output)`,
  `fileChange(files, status)`, `other(type)` (rendered as a quiet generic
  row — unknown item types must not crash or vanish silently).
- Approval responses resolve the pending server request with
  `accept` / `acceptForSession` / `decline`.

`chatThreadId: String?` is added to `NoteRecordingState` (forward-compatible
decoding, same as `fixerThreadId`).

## 2. SimbiUI

### ChatWindow scene

`WindowGroup("Chat", id: ChatWindow.windowId, for: URL.self)` in `SimbiApp`,
mirroring the fixer window. The NoteView toolbar button becomes
`openWindow(value: noteFolderURL)`; the deeplink code path is deleted.
Default size ~480×620, resizable.

### ChatModel (@Observable @MainActor)

Shared-per-note registry (`ChatModel.shared(noteFolderURL:)`) so state
survives window close/reopen. Holds: `messages: [ChatRow]`, streaming buffer
keyed by itemId, `turnStatus`, `pendingApproval`, `errorBanner`,
`isAvailable` (codex installed + authed). Bridges `ChatSession` events with
`Task { @MainActor in ... }`. On first appearance calls `ensureThread()` and
renders hydrated history.

### ChatView layout

Top to bottom:

1. **Header** — note name, model name (`.meta`, secondary), New Chat button,
   spinner while a turn runs.
2. **Transcript** — `ScrollView` + `LazyVStack`, bottom-anchored autoscroll
   that disengages when the user scrolls up; a "jump to latest" pill appears
   while disengaged (macai/Enchanted pattern).
3. **Composer** — multiline input pinned at bottom. Enter sends,
   Shift+Enter inserts a newline. Send button swaps to a stop (interrupt)
   button while a turn is active. Disabled with a hint when codex is
   missing/unauthenticated (same copy family as `NoteView.degradedBanner`).

Row types (all styled with `Design` — no bubbles, agent-console style):

- **User message** — full-width, subtle secondary background, `.body`.
- **Agent message** — markdown via `swift-markdown-engine`
  (`MarkdownEngine` + `MarkdownEngineCodeBlocks`), streamed deltas appended
  to the in-flight row; `item/completed` text is authoritative.
- **Command execution** — collapsed monospace row (command + status dot),
  disclosure reveals output.
- **File change** — file names + change kind summary.
- **Approval card** — inline card for `item/commandExecution/requestApproval`
  and `item/fileChange/requestApproval`: shows the command or file list with
  Accept / Accept for Session / Decline. Resolving collapses it into the
  normal item row. While an approval is pending the composer stays enabled
  only for interrupt.
- **Error banner row** — `StatusBanner` reuse for failed/interrupted turns
  and reconnects.

## 3. Error handling

- App-server death: `AppServerClient` auto-restarts on next request;
  `ChatSession` re-resumes the thread before the next `turn/start` and the
  UI shows a one-line reconnect notice.
- `turn/completed` status `failed`/`interrupted` → inline banner row,
  composer re-enabled.
- Resume failure → silent fallback to a fresh thread (old id discarded).
- Codex missing / signed out → composer disabled + status message; window
  still opens (shows history if hydrated previously in-session).

## 4. Testing

- `CodexKitTests` (run against the real app-server, like `CodexChatTests`):
  create → persist → resume round-trip; server-request response path
  (approval request answered).
- Pure unit tests: `ChatEvent` parsing from captured notification JSON;
  `ChatModel` behavior with a scripted event stream (delta accumulation,
  approval lifecycle, turn status transitions).
- UI verification via the `verify` flow with evidence under
  `docs/verification/2026-07-21-in-app-chat/`.

## Out of scope (v1)

Image/skill inputs, thread forking/steering, browsing other threads,
multi-thread history UI, chat detached from a note. The transcription path
and fixer/converter behavior are unchanged.

## SPEC.md impact

§5.4 is rewritten: "Chat in Codex" deeplink → in-app chat window, persistent
per-note `chatThreadId`, workspace-write + approvals. §6 gains the chat
window. (Done as part of implementation.)
