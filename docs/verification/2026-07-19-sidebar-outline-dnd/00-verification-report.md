# Simbi sidebar outline/DnD verification

- Build: `/Users/andyye/Library/Developer/Xcode/DerivedData/Simbi-gwtseuyyrzosuibtntlrmxmlldci/Build/Products/Debug/Simbi.app`
- Verified process: PID 42989, started Sun Jul 19 01:45:43 2026.
- Final test-folder state: `/Users/andyye/Simbi/ZZ Test B/ZZ Test A` exists; the test folders were left in place for inspection.

## Verdicts

1. **PASS — Render.** The sidebar renders an outline tree with disclosure triangles for folders and document icons for notes/files. Evidence: `01-sidebar-render.png`.
2. **PASS — Manual reorder.** The insertion-line indicator appeared during the drag; after dropping, `ZZ Test B` was immediately above `ZZ Test A`. The root `.simbi-order.json` was created and listed `ZZ Test B` before `ZZ Test A`. Evidence: `02-after-reorder.png`, `03-order-file.txt`.
3. **PASS — Move into folder.** Dropping `ZZ Test A` onto `ZZ Test B` moved it to disk and the expanded B row showed A nested beneath it. `ls ~/Simbi/"ZZ Test B"` returned `ZZ Test A`. Evidence: `04-after-move-into-folder.png`, `05-zz-test-b-ls.txt`.
4. **PASS — Context menu.** Right-clicking `ZZ Test B` showed New Note, New Folder, Rename…, Reveal in Finder, and Move to Trash. The menu was dismissed with Escape without invoking an item. Evidence: `06-context-menu.png`.

## Evidence paths

- `/Users/andyye/dev/simbi/docs/verification/2026-07-19-sidebar-outline-dnd/00-verification-report.md`
- `/Users/andyye/dev/simbi/docs/verification/2026-07-19-sidebar-outline-dnd/01-sidebar-render.png`
- `/Users/andyye/dev/simbi/docs/verification/2026-07-19-sidebar-outline-dnd/02-after-reorder.png`
- `/Users/andyye/dev/simbi/docs/verification/2026-07-19-sidebar-outline-dnd/03-order-file.txt`
- `/Users/andyye/dev/simbi/docs/verification/2026-07-19-sidebar-outline-dnd/04-after-move-into-folder.png`
- `/Users/andyye/dev/simbi/docs/verification/2026-07-19-sidebar-outline-dnd/05-zz-test-b-ls.txt`
- `/Users/andyye/dev/simbi/docs/verification/2026-07-19-sidebar-outline-dnd/06-context-menu.png`

## Notes

- Computer Use returned transient `-10005` errors and detected a changed app bundle; the stale process was replaced with the exact requested build before the successful verification sequence.
- Only the two throwaway test folders were moved. No real note was opened, dragged, renamed, deleted, or otherwise modified; no audio or audio-device action was performed.
