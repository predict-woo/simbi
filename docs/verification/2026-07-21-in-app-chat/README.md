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

## Result

All seven checks passed; the persistence fix (the original complaint)
is confirmed working.
