# OmaTable M4: structure editing, export and CSV import

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** See and change a table's structure (columns, indexes, foreign keys) with the DDL previewed before it runs; export a table or a query result to CSV, JSON or SQL; import a CSV file into a table; drop and truncate tables from the sidebar.

**Architecture:** Adapters gain `structure()` (catalog queries per engine) and `stream()` (batched rows without loading a whole result). A new `ddl` module turns staged structure changes into per-dialect `ALTER TABLE`/`CREATE INDEX` statements; `transfer` writes export files and reads CSV. The window gets a Data/Structure switch in table tabs, a sidebar context menu, and Export/Import/Confirm dialogs.

**Tech Stack:** Python 3.14 stdlib (csv, json) + psycopg 3.3, PyMySQL, sqlite3; Quickshell/QtQuick.

**Spec:** `docs/superpowers/specs/2026-10-25-omatable-design.md`

## Global Constraints

- Identifiers are always quoted by the dialect. Column types, defaults and index columns come from the user as SQL; types and defaults are rejected if they contain `;`, `--`, `/*` or a newline, and every DDL statement is shown before it runs.
- PostgreSQL and SQLite apply structure changes in one transaction. MySQL commits each DDL statement itself, so a failure there reports how many statements already ran.
- Export files are written to a temporary file and renamed into place, mode 600, never over an existing file unless asked.
- CSV import runs in one transaction; a bad row rolls everything back and names the row.
- SQL exports use dialect-correct literals (PostgreSQL bytea as `'\x…'::bytea`, MySQL strings with backslashes escaped).
- Tests: `/usr/bin/python3 -m unittest discover -s tests -t .`; database tests need `zt-pg`/`zt-my` and `OMATABLE_TEST_DB=1`.

---

## Interfaces

### Adapters
- `structure(schema, table) -> {"columns": [{"name", "type", "nullable", "default", "comment", "pk", "extra"}], "indexes": [{"name", "columns", "unique", "primary"}], "foreign_keys": [{"name", "columns", "ref_schema", "ref_table", "ref_columns", "on_update", "on_delete"}], "ddl": str}` — `default` is always a SQL expression (or `None`).
- `alter(schema, table, changes) -> {"statements": n}`; `alter_preview(schema, table, changes) -> {"statements": [sql]}`.
- `stream(sql, params=None, batch=2000)` → yields `(names, rows)` batches.
- `drop(schema, table)`, `truncate(schema, table)`.

### `omatable/ddl.py`
- `statements(d, engine, schema, table, current, changes) -> [sql]` where `current` is `structure()` output and
  `changes = {"columns": [{"op": "add"|"drop"|"alter", ...}], "indexes": [{"op": "add"|"drop", ...}], "foreign_keys": [{"op": "drop", "name"}]}`.
  - add column: `name, type, nullable, default, comment`; alter: `name` plus any of `new_name, type, nullable, default, comment` (a present key is a change; `default: null` drops it).
  - Order: drop foreign keys, drop indexes, drop columns, alter, add columns, add indexes.
- `check_sql_fragment(text, what)`.

### `omatable/sqlgen.py`
- `literal(value, d=None)` dialect-aware; `select_all(d, schema, table, columns, sort, filters, match, extra="")`.

### `omatable/transfer.py`
- `export(adapter, target, fmt, path, overwrite=False, table_name=None) -> {"path", "rows", "bytes"}`; `target = {"schema", "table", "sort", "filters", "match"}` or `{"sql"}`; `fmt in ("csv", "json", "sql")`.
- `preview_csv(path, delimiter=None, limit=20) -> {"delimiter", "header", "rows", "count"}`.
- `import_csv(adapter, schema, table, path, mapping, delimiter=",", header=True, empty_null=True) -> {"inserted"}`.

### Protocol
`struct.get`, `struct.preview`, `struct.apply`, `table.drop`, `table.truncate`, `export.run`, `import.preview`, `import.run`.

### QML
`Structure.qml` (inside `TableTab`, Data/Structure switch), `ExportDialog.qml`, `ImportDialog.qml`, `Confirm.qml`; sidebar context menu (Open, Structure, Export…, Import CSV…, Truncate…, Drop…, Copy name); result tabs get **Export**; grid menu gets Copy row as JSON / as INSERT.

---

### Task 1: Structure read and DDL generation
**Files:** Create `omatable/ddl.py`; Modify adapters; Test `tests/test_ddl.py`, `tests/test_adapters.py`
- [ ] Unit tests for `ddl.statements` on all three dialects (add/drop/rename/alter type/null/default/comment, indexes, FK drop, ordering, SQLite refusals, fragment checks, MySQL CHANGE keeps auto_increment).
- [ ] Live tests: `structure()` columns/indexes/FKs/DDL per engine; `alter()` round trip; failing PostgreSQL alter rolls back.
- [ ] Implement, commit "Read table structure and apply DDL changes".

### Task 2: Streaming, export, CSV import, drop/truncate
**Files:** Create `omatable/transfer.py`; Modify `sqlgen.py`, adapters; Test `tests/test_transfer.py`
- [ ] Tests: CSV/JSON/SQL export of a table with NULL, bytes, unicode, `%`; filter applied; query export; refuse overwrite; mode 600; SQL export re-imports into a fresh table and matches; CSV preview sniffs `;`; import with mapping/skip/empty→NULL; bad row rolls back with its row number; drop/truncate.
- [ ] Implement, commit "Export tables and queries, import CSV, drop and truncate".

### Task 3: Protocol methods
**Files:** Modify `omatable/__main__.py`; Test `tests/test_session.py`
- [ ] Tests through `build()` for each new method on SQLite; commit "Add structure, export and import protocol methods".

### Task 4: Window
**Files:** Create `qml/Structure.qml`, `qml/ExportDialog.qml`, `qml/ImportDialog.qml`, `qml/Confirm.qml`; Modify `TableTab.qml`, `Sidebar.qml`, `Workspace.qml`, `ResultTabs.qml`, `DataGrid.qml`
- [ ] Structure view: editable column list (name, type, nullable, default, comment), add/drop column, index list with add/drop, FK list with drop, DDL tab; staged like data edits; Ctrl+S previews the DDL in a confirm dialog.
- [ ] Sidebar menu, export/import dialogs, confirm before drop/truncate.
- [ ] Click test on PostgreSQL, MariaDB and SQLite; commit "Add the structure view, export, import and table actions".

### Task 5: Docs and merge
- [ ] README, tick plan, full tests, merge to `main`.
