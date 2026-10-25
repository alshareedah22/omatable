# OmaTable M2: SQL sessions, tunnels, sidebar and data grid

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Connect to PostgreSQL, MySQL/MariaDB and SQLite (directly or over SSH), browse the schema in a sidebar, page/sort/filter a table in a data grid, and commit staged edits with Ctrl+S.

**Architecture:** `tablectl` gains a session registry. Each session owns one driver connection and one worker thread (DB-API connections are not shared across threads), plus an optional `ssh -L` tunnel. SQL is built by `sqlgen`, which quotes identifiers per dialect, validates every column against the table's real columns and binds every value. The window gains a `Workspace` view (sidebar, tabs, table tab = filter bar + grid + status bar).

**Tech Stack:** Python 3.14 stdlib + psycopg 3, PyMySQL, sqlite3; Quickshell/QtQuick.

**Spec:** `docs/superpowers/specs/2026-10-25-omatable-design.md`

## Global Constraints

- Values are always bound as parameters; identifiers are always quoted by the dialect and must exist in the table's column list.
- Passwords never appear in argv or the environment (SSH password via `SSH_ASKPASS` reading a private FIFO).
- A commit runs in one transaction; an UPDATE/DELETE that does not touch exactly one row rolls the whole commit back.
- Tests run with `/usr/bin/python3 -m unittest discover -s tests -t .`; database tests use `zt-*` OmaDB servers and are skipped unless `OMATABLE_TEST_DB=1`.

---

## Interfaces

### `omatable/sqlgen.py`

- `DIALECTS = {"postgresql": Dialect('"', "%s", ilike=True), "mysql": Dialect("`", "%s"), "sqlite": Dialect('"', "?")}`; `dialect(engine)` maps mariadb → mysql.
- `Dialect.quote(name)`, `Dialect.table(schema, name)`.
- `OPS = ("=", "<>", "<", ">", "<=", ">=", "contains", "not_contains", "starts", "ends", "in", "null", "not_null")`
- `where(d, columns, filters, match="and") -> (sql, params)`; `filters = [{"column", "op", "value"}]`.
- `select(d, schema, table, columns, sort=(), filters=(), match="and", limit=300, offset=0, extra="") -> (sql, params)`; `sort = [{"column", "desc": bool}]`.
- `count(d, schema, table, columns, filters=(), match="and") -> (sql, params)`.
- `changes(d, schema, table, columns, key, changes) -> [(sql, params, expect_one)]`; `changes = {"updates": [{"key": {...}, "values": {...}}], "inserts": [{"values": {...}}], "deletes": [{"key": {...}}]}`; order: deletes, updates, inserts.
- `literal(value)` / `render(d, sql, params)` for "Preview SQL" only.
- `decode(value)` turns `{"$t": "bytes", "v": b64}` back into bytes.

### `omatable/tunnel.py`

- `Tunnel(ssh, target_host, target_port, password=None)`; `.start(timeout=20)` → local port; `.close()`; `.alive()`.
- Raises `Error("tunnel", <ssh stderr>)`.
- `omatable/askpass` prints the password read from `$OMATABLE_ASKPASS_FIFO`.

### `omatable/adapters/`

- `base.SQLAdapter(conn)`: `connect()`, `close()`, `version()`, `databases()`, `use(db)`, `tree()`, `columns(schema, table) -> [{"name","type","nullable","default","pk"}]`, `key(schema, table, columns) -> [names]`, `rows(...)`, `count(...)`, `preview(...)`, `commit(...)`.
- `postgres.Postgres`, `mysql.MySQL`, `sqlite.SQLite`; `adapters.create(conn)`.
- Errors map to codes `auth`, `network`, `notfound`, `sql`.

### `omatable/session.py`

- `Sessions(store)`: `open(conn_id) -> dict`, `test(conn) -> dict`, `get(sid)`, `close(sid)`, `close_all()`.
- `Session.run(fn, *args)` executes on the session's single worker thread.

### Protocol methods added

`conn.test(conn)`, `session.open(id)`, `session.close(session)`, `session.databases(session)`, `session.use(session, database)`, `schema.tree(session)`, `table.rows(session, schema, table, offset, limit, sort, filters, match)`, `table.count(session, schema, table, filters, match)`, `table.preview(session, schema, table, changes)`, `table.commit(session, schema, table, changes)`.

`table.rows` returns `{"columns": [{"name","type","pk","hidden"}], "rows": [[...]], "key": [...], "editable": bool, "offset", "limit", "ms"}`.

## Tasks

### Task 1: sqlgen
- [x] Tests `tests/test_sqlgen.py`: quoting per dialect (embedded quote doubled), unknown column rejected (`invalid`), unknown op rejected, each op's SQL and params, IN splits a comma list, LIKE escapes `%`/`_`, sort multi-column, limit/offset bound, count, changes order + expect_one, inserts with no values use DEFAULT VALUES, update with empty key rejected, render inlines literals.
- [x] Implement `omatable/sqlgen.py`; tests pass; commit.

### Task 2: SSH tunnel
- [x] Tests `tests/test_tunnel.py`: free port picker; argv contains no password and has `ExitOnForwardFailure`; askpass prints FIFO content; failure (closed port on 127.0.0.1:1) raises `tunnel` with stderr; end-to-end through a private unprivileged `sshd` (temp host key, key auth, skipped if `/usr/bin/sshd` missing) forwarding to a local TCP echo server.
- [x] Implement `omatable/tunnel.py` + `omatable/askpass`; commit.

### Task 3: adapters
- [x] Tests `tests/test_adapters.py`: SQLite always (temp file): tree, columns, key, rows sort/filter/paging, count, commit update/insert/delete, rollback when a key matches nothing, rowid editing for keyless tables, views not editable. PostgreSQL and MySQL against `zt-pg`/`zt-my` OmaDB servers when `OMATABLE_TEST_DB=1`: same flow plus databases/use and auth failure → `auth`.
- [x] Implement `base.py`, `sqlite.py`, `postgres.py`, `mysql.py`, `__init__.py`; commit.

### Task 4: sessions + protocol
- [x] Tests `tests/test_session.py`: open a saved SQLite connection, rows over the protocol, unknown session → `notfound`, conn.test with unsaved form data, close releases; OmaDB connection ids resolve through `omadb.server`.
- [x] Implement `omatable/session.py`, register methods in `__main__.py`, close all sessions on exit; commit.

### Task 5: themed controls
- [x] `qml/Btn.qml`, `qml/Combo.qml` in the Omarchy theme; replace stock Button/ComboBox in Welcome/ConnectionForm/Panel; dim disabled fields; opaque window background. Add Test and Connect buttons to the form. Click-test; commit.

### Task 6: workspace
- [x] `qml/Workspace.qml` (title strip, database switcher, back button, sidebar, tabs), `qml/Sidebar.qml` (search + tree), `qml/TableTab.qml` (filter bar, grid, status bar, staged edits, Ctrl+S, Ctrl+Shift+Delete, Ctrl+I, Delete, Preview SQL), `qml/DataGrid.qml`, `qml/FilterBar.qml`. Panel routes Welcome ↔ Workspace.
- [x] Click-test against `zt-pg`: connect, open table, sort, filter, edit a cell, Ctrl+S, insert, delete, preview; commit.

### Task 7: wrap-up
- [x] Full test run with `OMATABLE_TEST_DB=1`; README section; merge to main.
