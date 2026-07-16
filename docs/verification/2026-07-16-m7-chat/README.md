# M7 chat + model-list verification — 2026-07-16

`swift run --package-path Packages/SimbiKit simbi-chat-spike` — real
end-to-end against the live app-server (`spike-output.log`):

```
PASS models: 7 available — gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna,
             gpt-5.5, gpt-5.4, gpt-5.4-mini, gpt-5.3-codex-spark
chat thread: 019f6ad6-3fe6-7dd1-b28c-a54a6b89db1d
PASS chat: named "M5 Files Demo — chat", cwd = home root, 1 turn(s)
OVERALL: PASS
```

- **`model/list`** (§5.5) returns real slugs; the Settings pickers show
  them under a "Default" (= no override) first entry. Overrides are passed
  as `model` on `turn/start` for fixer/converter/chat turns.
- **Chat in Codex** (§5.4): thread started with `cwd = ~/Simbi` (home
  root, never the note folder), named `<note> — chat`, context turn
  completed (the agent reads the note while the user types). The app opens
  `codex://threads/<id>` and never archives chat threads — the spike
  archived its own thread purely as test hygiene.

UI evidence (rename popover, settings pane, chat button/deeplink) is under
`../2026-07-16-m7-ui/`.
