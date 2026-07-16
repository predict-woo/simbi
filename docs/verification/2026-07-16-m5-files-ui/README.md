# M5 files-section UI verification — 2026-07-16

Read-only UI check by an Orca-dispatched Codex computer-use worker against
the running Debug build, on a demo note (`~/Simbi/M5 Files Demo`) with
prefilled conversion states. Screenshots verified by the coordinator's own
eyes.

- `02-files-section.png` — the files section below the markdown editor:
  "Files" header with **Add Files…**, `broken.xyz` with red **failed** text
  and a retry button, `report.pdf` with a **context** link button. No
  clipping, overlap, or crashes.
- `03-context-opened.png` — clicking **context** opened
  `context/report.pdf.md` (in the default .md app) with the converted
  content.

## Gotcha found during verification

- `01-files-section.png` — the first attempt legitimately failed: `open
  Simbi.app` had focused a **stale instance** running since before the M5
  build (no files section in the binary). Diagnosed via the process start
  time and by grepping the fresh `Simbi.debug.dylib` for an M5 UI string.
  Kill the running instance before relaunching for UI verification.

Converter-thread E2E evidence is under `../2026-07-16-m5-converter/`.
