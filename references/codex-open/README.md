# ChatGPT desktop app (Codex) deeplinks & app-server

How to programmatically open a chat in the ChatGPT macOS desktop app scoped to a
specific directory. Verified working on 2026-07-15 against ChatGPT.app with
bundled `codex-cli 0.144.2`. Everything here is undocumented and may change
between app versions.

## TL;DR

```bash
./open-codex-thread.py ~/dev/some-project "optional thread name"
```

Creates a thread with `cwd` set to that directory via the bundled
`codex app-server`, names it (required — see gotcha #2), then opens
`codex://threads/<id>` which focuses the ChatGPT app on that chat.

## The deeplink scheme

The app registers the `codex://` URL scheme (see `CFBundleURLTypes` in
`/Applications/ChatGPT.app/Contents/Info.plist`; bundle id is
`com.openai.codex`). Routes found in the app bundle (`app.asar`):

| URL | Opens |
|---|---|
| `codex://threads/<thread-id>` | a specific chat |
| `codex://settings` | settings |
| `codex://settings/connections` | connections settings |
| `codex://settings/computer-use/google-chrome` | computer-use settings |
| `codex://connector/oauth_callback` | internal (OAuth flows) |

Notes:

- There is **no** `codex://threads/new` route — you cannot deeplink straight
  into "new chat at path X". Hence the app-server dance below.
- The deeplink parser also reads an `accountId` query param
  (`codex://threads/<id>?accountId=...`), presumably for workspace targeting.
  Unverified.
- Plain `https://chatgpt.com/...` URLs do **not** open the app (no
  associated-domains entitlement); only `codex://` links route to it.
- The app itself has a "Copy deeplink" command on a thread (command palette /
  thread header menu) that produces `codex://threads/<id>`.

## Creating a thread at a path (app-server)

The app ships the codex CLI at
`/Applications/ChatGPT.app/Contents/Resources/codex`. Its `app-server`
subcommand speaks JSON-RPC 2.0 as newline-delimited JSON over stdio:

```
→ {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"me","title":"me","version":"1.0"}}}
← {"id":0,"result":{...}}
→ {"jsonrpc":"2.0","method":"initialized"}
→ {"jsonrpc":"2.0","id":1,"method":"thread/start","params":{"cwd":"/Users/andyye/dev/some-project"}}
← {"id":1,"result":{"thread":{"id":"019f...","path":".../rollout-....jsonl","cwd":"...",...}}}
→ {"jsonrpc":"2.0","id":2,"method":"thread/name/set","params":{"threadId":"019f...","name":"my chat"}}
← {"id":2,"result":...}
```

Then `open "codex://threads/<id>"`.

Docs: https://learn.chatgpt.com/docs/app-server

## Gotchas (both produce "no rollout found for thread id ...")

1. **CODEX_HOME must be `~/.codex`.** The app's own app-server process (spawned
   as `Resources/codex ... app-server` by the app) runs against `~/.codex` —
   confirmed via `lsof` on its pid. But the same binary launched standalone
   defaults to a private home at
   `~/Library/Application Support/orca/codex-runtime-home/home` ("orca" is the
   app's data dir). A thread created there is invisible to the app. Always run
   with `CODEX_HOME=~/.codex`. (The two homes hardlink-share rollout files for
   threads the app knows about, which makes this extra confusing.)

2. **A bare `thread/start` is lazy.** The rollout `.jsonl` under
   `~/.codex/sessions/YYYY/MM/DD/` is only written once the thread has content;
   an empty thread evaporates when the app-server process exits, and the
   deeplink then fails to resume. Calling `thread/name/set` is the
   lightest-weight way to force persistence (a first user turn also works).

## Dead ends (so you don't retry them)

- `codex app-server proxy` — connects to an app-server "control socket"
  (default `<home>/app-server-control/app-server-control.sock`). The app's
  in-process server doesn't create one, and the default path under the orca
  home exceeds the Unix-socket `SUN_LEN` limit anyway.
- `~/Library/Application Support/orca/daemon/daemon-v21.sock` — the app
  helper's socket. Accepts a handshake
  `{"type":"hello","token":<contents of daemon-v21.token>,"version":21}` but
  rejects raw JSON-RPC after it ("Expected hello"); the envelope format for
  subsequent messages is unknown.

## Useful protocol methods

Full protocol dump: `codex app-server generate-ts --out <dir>` (or
`generate-json-schema`). Thread lifecycle methods include `thread/start`,
`thread/resume`, `thread/read`, `thread/list`, `thread/name/set`,
`thread/fork`, `thread/archive`, `thread/delete`, `thread/compact/start`,
`thread/rollback`.

## Where state lives

| Path | What |
|---|---|
| `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl` | thread transcript (the "rollout") |
| `~/.codex/state_5.sqlite` → `threads` table | thread index (id, rollout_path, cwd, title, ...) |
| `~/.codex/session_index.jsonl` | legacy name index |
| `~/Library/Application Support/orca/` | app data dir (Electron); `codex-runtime-home/home` mirrors the layout above |
| `~/Library/Logs/com.openai.codex/YYYY/MM/DD/*.log` | app logs — grep a thread id here to debug deeplink routing |
