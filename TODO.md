# TODO — Sheet Viewer

Running tab. Current state at top, then next up, waiting-on, recently shipped. Prune every session.

## Where things stand (2026-10-06)
- First version, built and installed 2026-10-06: `~/Applications/Sheet Viewer.app` (id `com.chris.sheetviewer`). On Chris's Mac it is the default opener for CSV, TSV, Excel and Numbers files (`./build.sh --default`); Tablecruncher and the older Numbers to CSV app went to the Trash the same day.
- Public repo, MIT: https://github.com/chris-jk/sheet-viewer. `main` pushed 2026-10-06; the installed build matches it.
- Scope, in Chris's words: view, sort, search, and "the simple stuff" for editing. His worry: "are we getting to the point of where we're going to make it heavy?" No formulas, charts or layout. A new feature should be a list operation or a display rule.
- Checks: `SheetViewer --selftest` (build.sh runs it) and `SheetViewer --snapshot file out.png --do "…"`, which runs the real actions on an off-screen window and draws it to a PNG. Commands are listed above `run(script:)` in `main.swift`.
- Not covered by those checks, and not yet tried by hand: the Export save panel, the alert sheets (close, reload, quit, add page, a link that is not a web page), and a real mouse click on a link.
- Code review 2026-10-06 (whole folder): 15 findings, all fixed, each re-run against the reviewer's failing case.
- The README screenshot comes from a made-up workbook. Never take one from a real file.

## ⏭️ Next session — start here
- [ ] Carry raw numbers through an Excel export (first item under Next up)

## 🚨 Blocking
- (none)

## 🙋 Owner only
- [ ] Try the dialogs once: Export… (⌘S), closing a window with unexported changes, and adding a page. The code under them was run off screen; the dialogs themselves were never clicked.

## 🟡 Next up
- [ ] An Excel export writes each number as shown, so a value displayed rounded is exported rounded (0.3333 shown as 33% goes out as 0.33). For cells nobody edited, carry the raw value and its number format from `read.py` through `main.swift` to `write.py`.
- [ ] The Excel export runs `write.py` on the main thread: a very large workbook freezes the window until it returns. Move it off the main thread and say that it is working.

## 🧊 Later
- [ ] Every search keystroke recounts matches on every page, and every edit re-analyses every column. Fine at 300,000 rows on one page; revisit for workbooks with many big pages.
- [ ] Rename a page; add, delete and rename columns. A new page copies the current page's columns because there is no way to add one.
- [ ] Remember colors added to a CSV between opens. Chris passed on it 2026-10-06 ("we did good for now").
- [ ] The README says nothing in it should need newer than macOS 13; that is untried, and `swiftc` targets the host OS.

## ⏳ Waiting on others
- (none)

## ✅ Recently shipped (trim as it ages)
- 2026-10-06 — First version: tabs per page, sort, search, clickable links, file styling, cell / row / page editing with undo, row and cell colors, CSV and Excel export, review fixes.
