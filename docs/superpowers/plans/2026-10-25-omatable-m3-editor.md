# OmaTable M3: SQL editor, results, history and cancel

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Query tabs with a highlighted SQL editor: Ctrl+Enter runs the statement under the cursor (or the selection), Ctrl+Shift+Enter runs everything, each statement's result opens in its own result tab, a running query can be cancelled, and every run is kept in a searchable history next to saved queries.

**Architecture:** `tablectl` splits the editor text into statements itself (`sqlsplit`, aware of quotes, comments, dollar quotes and trigger bodies), runs them one by one on the session worker and stops at the first error. `query.cancel` runs off the worker and interrupts the driver (psycopg `cancel_safe`, MySQL `KILL QUERY` on a side connection, sqlite `interrupt`). History and saved queries are small 600-mode files next to `connections.json`. The window gains `QueryTab` (editor + results + drawer); results reuse `DataGrid` through a read-only `ResultModel`.

**Tech Stack:** Python 3.14 stdlib + psycopg 3.3, PyMySQL 1.x/2.x, sqlite3; Quickshell/QtQuick.

**Spec:** `docs/superpowers/specs/2026-10-25-omatable-design.md`

## Global Constraints

- The helper never interpolates anything into user SQL; it runs the statement text as written, without parameters.
- A run stops at the first failing statement; earlier results stay visible.
- Results keep at most `MAX_ROWS = 1000` rows per statement and say when they were cut.
- History and saved-query files are mode 600 in a 700 directory (SQL can contain secrets).
- Tests: `/usr/bin/python3 -m unittest discover -s tests -t .`; database tests need `zt-pg`/`zt-my` and `OMATABLE_TEST_DB=1`.

---

## Interfaces

### `omatable/sqlsplit.py`
- `split(text, engine) -> [(start, end, sql)]` — `start` is the first non-blank character, `end` the index after the `;` (or after the last character); `sql` is the statement without its `;`, stripped. Statements that hold only comments are dropped.
- `at(text, pos, engine) -> (start, end, sql) | None` — the last statement starting at or before `pos`, else the first.
- `keyword(sql) -> str` — first keyword, uppercased, after comments and `(`.
- Handles `'…'` (`''`, and backslash escapes for MySQL and `E'…'`), `"…"`, MySQL backticks, SQLite `[…]`, `-- ` / `#` (MySQL) / `/* */` comments (nested in PostgreSQL), `$tag$…$tag$`, and `BEGIN … END` bodies of `CREATE TRIGGER/PROCEDURE/FUNCTION/EVENT`.

### Adapters (`base.SQLAdapter`)
- `run(statements, max_rows=MAX_ROWS) -> {"results": [...], "database": str}`; each result is one of
  - `{"sql", "columns": [{"name", "type"}], "rows", "truncated": bool, "ms"}`
  - `{"sql", "affected": int, "ms"}`
  - `{"sql", "error": {"code", "message"}, "ms"}` (always last).
- `cancel()` — thread safe; sets `cancelled` and interrupts a running statement. A statement finishing after a cancel is reported as `{"code": "cancelled"}`.
- hooks: `describe(cursor) -> [type names]`, `interrupt()`.

### `omatable/history.py`
- `History(directory, keep=1000)`: `add(entry) -> entry` (adds `ts`), `list(conn=None, search="", limit=200)` newest first, `clear(conn=None)`.
- `Saved(directory)`: `list()`, `save(name, sql, id=None) -> item`, `delete(id)`.

### Protocol
- `query.run(session, text, cursor=None)` → adapter result + `"range": [start, end]`, `"ddl": bool`.
- `query.cancel(session)` → `{"ok": true}`.
- `query.history(conn=None, search="", limit=200)`, `query.history_clear(conn=None)`.
- `query.save(name, sql, id=None)`, `query.saved()`, `query.delete_saved(id)`.
- `app.palette()` → `{"keyword", "string", "number", "comment", "identifier"}` colours from the Omarchy theme's `colors.toml` (empty when it has none).

### QML
- `qml/SqlHighlight.js` (`.pragma library`): `html(text, engine, palette) -> string`.
- `qml/CodeEditor.qml`: editor with line numbers and highlighting (`text`, `engine`, `palette`, `cursorPosition`, `selectedText`, `selectionStart`, `selectionEnd`, `select(a, b)`, `insert(text)`).
- `qml/ResultModel.qml`: the `DataGrid` tab interface over one result (read-only, client-side sort).
- `qml/ResultTabs.qml`: tabs over `results`.
- `qml/QueryTab.qml`: toolbar, editor, results, history/saved drawer.
- `Workspace.qml`: tabs carry `kind` (`table`/`query`) and `title`; Ctrl+T and "+ Query" open query tabs.

---

### Task 1: Statement splitter

**Files:** Create `omatable/sqlsplit.py`; Test `tests/test_sqlsplit.py`

- [x] Write tests: plain split with offsets; `;` inside `'…'`, `"…"`, backticks, comments; `''` and MySQL `\'`; `$$…;…$$` and `$fn$`; nested `/* /* */ */` in PostgreSQL; MySQL `#` comment and `--x` not being a comment in MySQL; comment-only trailing statement dropped; SQLite trigger with `BEGIN … ; … END;` kept whole; `at()` inside, between and after statements; `keyword()` with leading comments and parentheses.
- [x] Run, see them fail; implement a single-pass scanner; run, see them pass.
- [x] Commit "Add the SQL statement splitter".

### Task 2: Run and cancel in the adapters

**Files:** Modify `omatable/adapters/base.py`, `postgres.py`, `mysql.py`, `sqlite.py`; Test `tests/test_adapters.py`

- [x] Tests (SQLite always): select returns columns/rows; `max_rows` truncates; insert reports `affected`; error stops the run and keeps earlier results; cancel from another thread interrupts a long recursive CTE with `cancelled`; a NaN is cleaned.
- [x] Live tests: PostgreSQL `SELECT pg_sleep(30)` cancelled within 5 s and the session still answers `SELECT 1`; column type names (`integer`); MySQL `SELECT SLEEP(30)` cancelled, `USE` updates `database`.
- [x] Implement `run`, `cancel`, `describe`, `interrupt`, error mapping (`57014`, `1317`, sqlite `interrupted` → `cancelled`); MySQL connection params factored into `_params()` for the side connection.
- [x] Commit "Run statements and cancel them in every SQL adapter".

### Task 3: History, saved queries and protocol methods

**Files:** Create `omatable/history.py`; Modify `omatable/__main__.py`, `omatable/session.py`; Test `tests/test_history.py`, `tests/test_session.py`

- [x] Tests: history add/list newest first, search, per-connection filter, trim to `keep`, mode 600, clear; saved save/rename/delete; `query.run` with cursor runs one statement and returns its range; run all; `ddl` true for `CREATE`; a run lands in history with `ok`/`error`; `query.cancel` from a second thread while `query.run` blocks; `app.palette` reads a fake `colors.toml`.
- [x] Implement; `Session.cancel()` calls the adapter directly (not through the worker); DDL runs call `adapter.forget()`.
- [x] Commit "Add query.run/cancel, history and saved queries".

### Task 4: Editor, results and query tabs

**Files:** Create `qml/SqlHighlight.js`, `qml/CodeEditor.qml`, `qml/ResultModel.qml`, `qml/ResultTabs.qml`, `qml/QueryTab.qml`; Modify `qml/Workspace.qml`, `qml/DataGrid.qml`

- [x] `CodeEditor`: a transparent-text `TextEdit` over a rich-text `TextEdit` showing `SqlHighlight.html()` (same font, no wrap, same padding, so glyphs line up), line-number gutter, Tab inserts two spaces, auto-indent on Enter.
- [x] `ResultModel` + `DataGrid`: read-only (`editable: false`), menu shows only copy actions, header click sorts in memory.
- [x] `QueryTab`: Run (Ctrl+Enter), Run all (Ctrl+Shift+Enter), Cancel (visible while running, with elapsed seconds), Save (Ctrl+S, name popup), drawer (Ctrl+H) with History (search, click loads into editor, Clear) and Saved (click loads, ✕ deletes); errors inline in the result area (monospace, so carets line up); results clear while a run is in progress.
- [x] `Workspace`: query tabs, Ctrl+T, "+ Query" button, reload the tree after DDL, follow MySQL `USE`.
- [x] Restart the shell; click test against `zt-pg`, `zt-my` and a SQLite file: run current/all, error, cancel `pg_sleep`, history reload, save/load, sort a result, copy a cell.
- [x] Commit "Add query tabs: SQL editor, result tabs, history and saved queries".

### Task 5: Docs and merge

- [x] README: query tab usage and shortcuts. Tick this plan. Full test run (venv + live). Merge to `main`.
