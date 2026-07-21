# In-app Codex chat window verification — 2026-07-21

"Chat in Codex" (deeplink to the ChatGPT app, which opened an empty
conversation every time) was replaced by an in-app per-note chat window
over `codex app-server` (SPEC.md §5.4): one persistent thread per note
(`chatThreadId` in `.simbi/state.json`), resume + `thread/read` hydration
on reopen, streaming agent markdown, command/file-change rows, inline
approval cards, workspace-write turns with `approvalPolicy: on-request`.
Verified live against the real app-server on the "M5 Files Demo" note; no
recording started, no audio played.

- **01-chat-window-opened.png** — toolbar Chat button opens the window
  titled "Chat — M5 Files Demo" with header (New Chat), transcript, and
  composer.
- **02-response-complete-with-swift-code.png** — sent message appears
  instantly as a "You" row; Codex reply streams in and renders the fenced
  Swift block monospaced in a rounded box. "Thinking…" quiet rows and
  green-dotted command rows interleave correctly. (The reply was short, so
  no mid-stream screenshot was caught; deltas were observed live.)
- **03-chat-reopened-persisted.png** — the original bug's fix: closing and
  reopening the window restores the same conversation via
  `thread/resume` + hydration. `state.json` held
  `chatThreadId = 019f83f8-5ee3-72c1-b3d9-1eb0609ae531` before and after.
- **04-git-status-auto-approved-command-row.png** — `git status` ran as a
  command row without an approval card: sandbox-safe commands inside the
  workspace-write root are auto-approved by the server under
  `on-request`, so no card is expected. Finding, not a failure (see
  below).
- **05/06-file-change-*.png** — "create chat-test.txt" completed as
  command/file rows; the file landed in `~/Simbi` with the right content
  (writes inside the cwd root don't escalate either).
- **07-latest-pill-visible.png** — scrolling up disengages the bottom pin;
  the "Latest" pill appears bottom-right and the view does not yank down;
  clicking it jumps back.
- **08-new-chat-cleared.png** — New Chat archives the thread
  (rotated to `019f83fa-461a-7c42-ad02-9a2a2f1be890` in state.json) and
  starts a clean transcript.

## Findings / known niggles

1. **Approval cards did not fire live.** Under `on-request` +
   workspace-write, everything the agent did stayed inside the sandbox, so
   the server never sent `item/commandExecution/requestApproval`. The
   server-request plumbing and card UI are covered by unit tests
   (`JSONRPCMessageTests`, ChatSession approval lifecycle); a live card
   needs an out-of-sandbox action (e.g. network). Worth a follow-up probe.
2. **The context prompt shows as the first "You" row** after hydration
   (it *is* a userMessage item on the wire). Cosmetic; could be filtered
   or restyled as a system row later.

## Round 2 — inline file attachments (context turn rework)

The context turn no longer tells the agent to go read the note's files;
their contents ride along inline in the context message (size-capped,
truncation pointers back to disk), with each file's cwd-relative path
named so edits land in the real files. The sentinel-marked context
message is hidden from the transcript live and on hydration — this also
resolved finding #2 above.

- **r2-01-fresh-thread-no-context-row.png** — New Chat thread built with
  the attachment prompt: no `[simbi note context]` row, no giant "You"
  row of file contents.
- **r2-02-answer-without-read-commands.png** — "What is this note about?"
  answered with ZERO command rows (previously the agent ran
  `find`/`wc`/reads first); the answer cites the note's actual content
  (the quarterly-targets PDF summary), proving the inline copies
  delivered.
- **r2-03-reopened-still-hidden.png** — close/reopen hydration still
  hides the context message; only the real exchange remains.

## Round 3 — no auto-sent turn; attachments ride the user's first message

Round 2 still auto-sent a context turn at thread creation. Reworked:
opening a chat only creates/names the thread; the attachment block
(files + on-disk paths) is prepended to the USER'S first message at send
time, and userMessage rows strip the block for display.

- **r3-01-empty-until-user-speaks.png** — fresh thread stays completely
  empty (placeholder only) for 20+ seconds; no agent turn, no
  acknowledgement message.
- **r3-02-clean-user-row-grounded-answer.png** — the user row shows
  exactly the typed text (attachment block invisible); the answer is
  grounded in the note's content with zero command rows.
- **r3-03-reopen-clean.png** — close/reopen hydration shows exactly the
  one exchange; the stored userMessage's attachment block is stripped.

## Result

All checks passed across three rounds: persistent per-note threads (the
original complaint), file attachments on the user's first message with
no auto-sent turns, and clean transcript rendering throughout.
