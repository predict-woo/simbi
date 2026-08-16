# AppServerSpike — M1 spike (b): codex app-server round-trip

Throwaway CLI proving the full `codex app-server` JSON-RPC lifecycle works
end-to-end: **spawn → initialize → thread/start → thread/name/set →
turn/start → notification stream → turn/completed → thread/archive →
thread/resume → clean exit**. This is the reference for building CodexKit's
real client.

Verified 2026-07-16 against `/Applications/ChatGPT.app/Contents/Resources/codex`
(`codex-cli 0.144.5`), macOS 26.3, ChatGPT auth (`authMethod: "chatgpt"`).
All 9 steps PASS; the model replied `pong` (one trivial turn, ~18k input /
5 output tokens — the user's global `~/.codex` config piles plugins, hooks,
and MCP servers onto every turn, see gotchas).

```sh
swift run --package-path Packages/SimbiKit simbi-appserver-spike
```

## Transport

- Child process: `codex app-server`, newline-delimited JSON-RPC 2.0 over
  stdio. One JSON object per line, both directions.
- **`CODEX_HOME=$HOME/.codex` is mandatory** (references/codex-open/README.md
  gotcha #1) — otherwise threads land in a private home invisible to the app.
  The initialize response echoes `"codexHome"` so you can assert it.
- stderr is quiet in practice; pipe it to a log file anyway.
- Closing the child's stdin makes the server exit cleanly (< 1 s in testing).
- Message taxonomy on stdout: `{id, result|error}` = response;
  `{method, params}` = notification; `{id, method, params}` = **server→client
  request** (approvals etc. — none arrive with `approvalPolicy: "never"`, but
  a real client must answer them or the turn stalls).

## Exact shapes that worked (real wire lines, nothing redacted — no tokens appear)

### initialize / initialized

```
→ {"id":0,"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"simbi-spike","title":"Simbi M1 spike","version":"0.1.0"}}}
← {"id":0,"result":{"userAgent":"simbi-spike/0.144.5 (Mac OS 26.3.0; arm64) Orca/1.4.139 (simbi-spike; 0.1.0)","codexHome":"/Users/andyye/.codex","platformFamily":"unix","platformOs":"macos"}}
→ {"jsonrpc":"2.0","method":"initialized"}
```

`params.capabilities` is optional; omitting it works. Interesting option for
CodexKit: `capabilities.optOutNotificationMethods: [string]` suppresses noisy
notifications per connection.

### getAuthStatus (preflight)

```
→ {"id":1,"jsonrpc":"2.0","method":"getAuthStatus","params":{"includeToken":false,"refreshToken":false}}
← {"id":1,"result":{"authMethod":"chatgpt","authToken":null,"requiresOpenaiAuth":true}}
```

`authMethod: null` ⇒ not logged in; bail before burning a turn.

### thread/start

```
→ {"id":2,"jsonrpc":"2.0","method":"thread/start","params":{"approvalPolicy":"never","cwd":"/var/folders/.../T/simbi-appserver-spike-D11228A7","sandbox":"read-only"}}
← {"id":2,"result":{"thread":{"id":"019f6a0e-ee3d-7630-b583-b9b10add783c","sessionId":"019f6a0e-...","preview":"","ephemeral":false,"status":{"type":"idle"},"path":"/Users/andyye/.codex/sessions/2026/07/16/rollout-2026-07-16T17-33-11-019f6a0e-....jsonl","cwd":"...","cliVersion":"0.144.5","source":"vscode","name":null,"turns":[]},"model":"gpt-5.6-sol","modelProvider":"openai","serviceTier":"priority", ...}}
```

- `sandbox` here takes a **`SandboxMode` string**: `"read-only" |
  "workspace-write" | "danger-full-access"`.
- `approvalPolicy` (`AskForApproval`): `"untrusted" | "on-request" | "never"`
  (plus a granular object form).
- Also accepts `model`, `ephemeral` (don't set — we want persistence),
  `baseInstructions`, `developerInstructions`, `config` overrides.
- A `thread/started` notification follows the response.

### thread/name/set (forces rollout persistence — gotcha #2)

```
→ {"id":3,"jsonrpc":"2.0","method":"thread/name/set","params":{"name":"[simbi] m1 spike 2026-07-16T08:33:11Z","threadId":"019f6a0e-ee3d-7630-b583-b9b10add783c"}}
← {"id":3,"result":{}}
← {"method":"thread/name/updated","params":{"threadId":"019f6a0e-...","threadName":"[simbi] m1 spike 2026-07-16T08:33:11Z"}}
```

### turn/start

```
→ {"id":4,"jsonrpc":"2.0","method":"turn/start","params":{"approvalPolicy":"never","input":[{"text":"Reply with exactly the word pong and do nothing else.","text_elements":[],"type":"text"}],"sandboxPolicy":{"networkAccess":false,"type":"readOnly"},"threadId":"019f6a0e-ee3d-7630-b583-b9b10add783c"}}
← {"id":4,"result":{"turn":{"id":"019f6a0e-f59e-7b90-812a-50d130ebf075","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}
```

- `input` is `Array<UserInput>`; the text variant is
  `{"type":"text","text":"...","text_elements":[]}` (note **snake_case**
  `text_elements`, unlike everything else — it's required-shaped in the TS
  dump; an empty array works). Other variants: `image` (url), `localImage`
  (path), `skill`, `mention`.
- Per-turn overrides exist and worked: `approvalPolicy` (same enum as above)
  and `sandboxPolicy`, which — unlike thread/start — takes the **tagged
  `SandboxPolicy` object**: `{"type":"readOnly","networkAccess":false}` /
  `{"type":"workspaceWrite","writableRoots":[...],"networkAccess":bool,
  "excludeTmpdirEnvVar":bool,"excludeSlashTmp":bool}` /
  `{"type":"dangerFullAccess"}`. Also `model`, `effort`, `summary`,
  `outputSchema`, `cwd`.
- The response returns immediately with `status: "inProgress"`; content
  arrives as notifications.

### Notification stream for a turn (order observed)

```
turn/started                     {threadId, turn}
hook/started / hook/completed    (user's ~/.codex plugins run inside the turn)
item/started                     {item:{type:"userMessage",...}, threadId, turnId, startedAtMs}
item/completed                   (the userMessage echo)
item/started                     {item:{type:"agentMessage","text":"","phase":"final_answer",...}}
item/agentMessage/delta          {threadId, turnId, itemId, delta:"pong"}
item/completed                   {item:{type:"agentMessage","text":"pong","phase":"final_answer",...}}
thread/tokenUsage/updated        {threadId, turnId, tokenUsage:{total:{totalTokens,inputTokens,cachedInputTokens,outputTokens,...}, modelContextWindow}}
account/rateLimits/updated       {rateLimits:{...planType, usedPercent...}}
thread/status/changed            {threadId, status:{type:"idle"}}
turn/completed                   {threadId, turn:{id, status:"completed", error:null, startedAt, completedAt, durationMs}}
```

**`turn/completed` is the terminal notification** — match on
`params.threadId` + `params.turn.id`; `turn.status` is
`"completed" | "interrupted" | "failed" | "inProgress"`, with
`turn.error: {message, codexErrorInfo, additionalDetails}` populated on
failure. Assemble the reply from `item/agentMessage/delta` deltas keyed by
`itemId`, or just take `item/completed` where `item.type == "agentMessage"`
(`item.text` is the full message). Other noise you must tolerate:
`mcpServer/startupStatus/updated` (one per configured MCP server, per thread
load), `remoteControl/status/changed`, `reasoning` deltas for thinking models.

### thread/archive

```
→ {"id":5,"jsonrpc":"2.0","method":"thread/archive","params":{"threadId":"019f6a0e-ee3d-7630-b583-b9b10add783c"}}
← {"id":5,"result":{}}
← {"method":"thread/archived","params":{"threadId":"019f6a0e-..."}}
```

Also emits `thread/status/changed → {type:"notLoaded"}` and cancels the
thread's MCP servers.

### thread/resume — NEW GOTCHA: archived threads refuse to resume directly

```
→ {"id":6,"jsonrpc":"2.0","method":"thread/resume","params":{"threadId":"019f6a0e-ee3d-7630-b583-b9b10add783c"}}
← {"id":6,"error":{"code":-32600,"message":"session 019f6a0e-... is archived. Run `codex unarchive 019f6a0e-...` to unarchive it first."}}
→ {"id":7,"jsonrpc":"2.0","method":"thread/unarchive","params":{"threadId":"019f6a0e-..."}}
← {"id":7,"result":{"thread":{...full Thread...}}}
→ {"id":8,"jsonrpc":"2.0","method":"thread/resume","params":{"threadId":"019f6a0e-..."}}
← {"id":8,"result":{"thread":{"id":"019f6a0e-...","name":"[simbi] m1 spike 2026-07-16T08:33:11Z","turns":[{...the pong turn, status:"completed"...}]}, "model":"gpt-5.6-sol", ...}}
```

So the archive→resume path is **archive → unarchive → resume**. The resumed
thread came back with the same id, its name, and `turns` populated
(user message + `agentMessage "pong"` — `turns` is only populated on
resume/rollback/fork/read responses, empty everywhere else). CodexKit should
call `thread/unarchive` first when reopening an archived thread.

## Gotchas discovered (beyond references/codex-open/README.md)

1. **Archived threads can't be resumed directly** — `-32600`; call
   `thread/unarchive` first (see above).
2. **The user's global `~/.codex` config applies to every thread**: plugin
   hooks (`hook/started`/`hook/completed` injected 5k+ chars of context),
   four MCP servers spun up per thread, `model`/`serviceTier` defaults from
   config. A trivial one-word turn cost ~18k input tokens. CodexKit may want
   `thread/start` `config`/`baseInstructions` overrides, or at minimum must
   tolerate hook/MCP notification noise.
3. **Two different sandbox param shapes**: `thread/start` takes
   `sandbox: "read-only"` (string `SandboxMode`); `turn/start` takes
   `sandboxPolicy: {"type":"readOnly","networkAccess":false}` (tagged
   `SandboxPolicy`). Easy to mix up.
4. `thread/start`'s response reports `source: "vscode"` for standalone
   app-server clients — don't key anything off it.
5. Responses and notifications interleave freely (e.g. `thread/started`
   arrived after the `thread/name/set` request was already in flight; the
   `thread/name/updated` notification arrived after the *next* request's
   send). A client needs a real demux loop, not lock-step request/response.
6. Protocol schema dump: `codex app-server generate-ts --out <dir>` — thread/
   turn types live in the `v2/` subdirectory (`TurnStartParams.ts`,
   `TurnCompletedNotification.ts`, ...); wire method names are in the
   top-level `ClientRequest.ts` / `ServerNotification.ts` unions.

## Side effects of a run

Each run creates (and leaves, deliberately — persistence is the point) one
real thread named `[simbi] m1 spike <timestamp>` in `~/.codex`, visible in
the ChatGPT app, unarchived (the final resume step unarchives it). Rollout
file: `~/.codex/sessions/YYYY/MM/DD/rollout-...jsonl`. Delete via
`thread/delete` or the app if the clutter bothers you.
