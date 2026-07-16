# M5 converter-thread verification — 2026-07-16

`swift run --package-path Packages/SimbiKit simbi-converter-spike` — a REAL
end-to-end run: FileConverter drove the real `codex app-server` against a
binary `.docx` (generated with `textutil` from text full of exact figures)
dropped into a note's `files/`.

```
files/report.docx: 3741 bytes
converter thread: 019f6a81-9269-7d41-9c42-1d36451c5e62
PASS fidelity: all 9 exact values present
PASS original: files/report.docx byte-identical
PASS state: conversion record persisted with thread id
OVERALL: PASS
```

The converter thread (workspace-write sandbox scoped to the note folder,
`approvalPolicy: never`, network off) read the .docx its own way and wrote
`context/report.docx.md` (`converted-report.docx.md` here) with zero
information loss: revenue `1,234,567.89 USD`, `17.3` percent, `4,096` users,
`42.195` minutes, `Jae-won Seo`, `2026-07-14`, and all six regional target
figures — and it upgraded the comma-separated region lines into a proper
markdown table on its own. `files/report.docx` stayed byte-identical, and
the thread was archived when the job ended.

Full spike output: `spike-output.log`.

UI evidence (files section rows, statuses, context link) is under
`../2026-07-16-m5-files-ui/`.
