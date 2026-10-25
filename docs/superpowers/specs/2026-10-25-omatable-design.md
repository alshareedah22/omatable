# OmaTable: design

A TablePlus-style database GUI for Omarchy, shipped as the shell plugin
`blackcode.omatable`. It is a companion to OmaDB: OmaDB runs local servers,
OmaTable connects to them (and to any other server) and lets you browse,
edit and query the data.

## Goals

- Feel like TablePlus: a welcome window listing connections, then a
  workspace with a schema sidebar, tabs, a fast data grid with staged edits
  committed by Ctrl+S, a SQL editor and a structure editor.
- Support every OmaDB engine: PostgreSQL, MySQL, MariaDB, SQLite,
  Redis/Valkey and MongoDB.
- Connect directly or through an SSH tunnel.
- Never trust an unpinned download; never store a password in plain text when
  a keyring is available.

Out of scope for v1: ER diagrams, query plans view, user/role management,
backup/restore (OmaDB territory), plugins/themes beyond the Omarchy theme.

## Architecture

```
 bar icon (Bar.qml) ──summon──► window (Panel.qml, FloatingWindow)
                                    │  JSON lines over stdin/stdout
                                    ▼
                               tablectl  (Python 3, one long-lived process)
                                    │  drivers in a pinned venv
            ┌──────────┬────────────┼───────────┬──────────┐
         psycopg    PyMySQL      sqlite3     redis-py   pymongo
                                    │
                              ssh -L tunnels
```

### Plugin files

| File | Purpose |
|---|---|
| `manifest.json` | id `blackcode.omatable`, kinds `bar-widget` + `panel` |
| `Bar.qml` | bar button; left click opens the window, right click lists recent connections |
| `Panel.qml` | the `FloatingWindow`; owns the helper process and routes views |
| `qml/*.qml` | view components: `Welcome`, `ConnectionForm`, `Workspace`, `Sidebar`, `DataGrid`, `FilterBar`, `QueryEditor`, `ResultTabs`, `Structure`, `RedisBrowser`, `MongoBrowser`, `ExportDialog`, `Confirm` |
| `tablectl` | Python entry point: venv bootstrap, then the JSON-lines server |
| `omatable/*.py` | helper package: `protocol`, `store` (connections + keyring), `tunnel`, `adapters/{postgres,mysql,sqlite,redis,mongo}.py`, `sqlgen`, `export` |
| `requirements.lock` | exact driver versions with sha256 hashes |
| `tools/update-requirements-lock` | maintainer tool regenerating the lock |
| `tests/` | protocol tests against `zt-*` OmaDB servers, plus UI click tests |

The window is opened with `omarchy-shell shell summon blackcode.omatable '{}'`.
When the window is closed, the shell hides the panel and the helper exits;
staged, uncommitted edits trigger a "discard changes?" prompt first.

### Helper runtime

- Runs on Arch's system `python` (always present on Omarchy).
- First launch creates `~/.local/share/omatable/venv` and runs
  `pip install --require-hashes --no-deps -r requirements.lock`, emitting
  progress events the window shows as "Installing database drivers…".
- The venv stores a stamp of the Python version and the lock hash; if either
  changes (Arch upgrades python, plugin update), it is rebuilt.
- Drivers: `psycopg[binary]`, `PyMySQL`, `redis`, `pymongo` (+ their deps,
  all pinned). SQLite uses the stdlib.

### Protocol

One JSON object per line.

- Request: `{"id": 7, "method": "table.rows", "params": {...}}`
- Reply: `{"id": 7, "result": {...}}` or `{"id": 7, "error": {"code": "auth", "message": "..."}}`
- Event (no id): `{"event": "progress", "text": "...", "pct": 40}`

Requests are handled on worker threads per session, so a slow query never
blocks the sidebar; `query.cancel` cancels the running statement (psycopg
`cancel`, MySQL `KILL QUERY` on a side connection, sqlite `interrupt`).

Methods:

| Group | Methods |
|---|---|
| connections | `conn.list`, `conn.save`, `conn.delete`, `conn.duplicate`, `conn.test`, `conn.omadb` (import OmaDB servers via `dbctl state`) |
| session | `session.open` → session id, `session.close`, `session.databases`, `session.use` (switch database) |
| schema | `schema.tree` (schemas → tables/views/functions/sequences), `schema.search` |
| data | `table.rows` (offset, limit, sort, filters), `table.count`, `table.commit` (changes) , `table.preview` (SQL a commit would run) |
| query | `query.run` (text, returns one result set per statement), `query.cancel`, `query.history`, `query.save`, `query.saved` |
| structure | `struct.get` (columns, indexes, foreign keys, DDL), `struct.preview`, `struct.apply` |
| transfer | `export` (table or query → CSV/JSON/SQL file), `import.csv` (preview + insert) |
| redis | `redis.scan`, `redis.get`, `redis.set`, `redis.del`, `redis.ttl`, `redis.cmd` |
| mongo | `mongo.find`, `mongo.count`, `mongo.insert`, `mongo.update`, `mongo.delete`, `mongo.indexes`, `mongo.run` |

Values cross the wire as JSON with a type tag for things JSON cannot hold
(`{"$t": "bytes", "v": "<base64>"}`, dates as ISO strings, decimals as
strings, Mongo ObjectId as `{"$oid": ...}`), so the grid never loses
precision and edits round-trip exactly.

### Adapters

Each engine implements one interface: `connect`, `databases`, `tree`,
`rows`, `count`, `commit`, `structure`, `run`, `cancel`, `close`.
SQL engines share `sqlgen`, which quotes identifiers per dialect and always
binds values as parameters; filters and sort columns are validated against the
table's real columns, never interpolated.

- PostgreSQL: schemas, tables, views, materialized views, functions,
  sequences; editing needs a primary key (or unique not-null key).
- MySQL/MariaDB: databases as the top level; same key rule.
- SQLite: a file path instead of host/port; `rowid` used when no key exists.
- Redis/Valkey: databases 0–15, SCAN with a pattern, typed viewers.
- MongoDB: databases → collections; documents edited as JSON (Extended JSON).

### Connections and secrets

- Stored in `~/.config/omatable/connections.json` (mode 600, dir 700):
  id, name, engine, host, port, user, database, color, tag
  (local/development/staging/production), SSH settings, SQLite path, TLS mode.
- Passwords (database and SSH) go to the Secret Service via `secret-tool`
  (attributes `app=omatable conn=<id> kind=db|ssh`). If no Secret Service
  answers, they are stored in the same 600 file and the form says so.
- OmaDB servers appear in their own "OmaDB" group, read live from
  `dbctl state` + `dbctl` credentials; they are not copied into the file
  unless the user edits one ("Save as connection").

### SSH tunnels

- Per connection: SSH host, port, user, and either key file, agent, or
  password.
- The helper picks a free local port and runs
  `ssh -N -L 127.0.0.1:<port>:<db-host>:<db-port> -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new user@host`,
  waits until the local port accepts, then connects the driver there.
- Password auth uses `SSH_ASKPASS` pointing at a tiny helper that reads the
  password from an inherited pipe (`SSH_ASKPASS_REQUIRE=force`); the password
  never appears in argv or the environment.
- Tunnels are closed with their session; a dead tunnel surfaces as a
  connection error with the ssh stderr.

## Window design

Follows the Omarchy theme colours and fonts (`Commons` style tokens).

### Welcome

Left: connection list grouped by tag, each row a colour strip, engine
icon, name, `user@host:port/db`; search box; OmaDB group with running
status. Right: empty state or the connection form. Buttons: New, Test,
Connect, Duplicate, Delete. Double click or Enter connects.

### Workspace

- Title strip coloured by the connection's colour; production connections get
  a red badge.
- Sidebar: database switcher, search, tree (tables, views, functions…),
  right-click: Open, Structure, Truncate, Drop, Export, Copy name.
- Tabs: each table or query opens a tab; Ctrl+T new query tab, Ctrl+W close.
- Table tab: filter bar (column · operator · value, multiple rows, AND/OR),
  grid, bottom bar with Data/Structure switch, row count, page size,
  previous/next page, refresh.
- Grid: column header click sorts (shift for multi-sort), resizable columns,
  NULL shown dimmed, double click or Enter edits, Tab moves to next cell,
  Ctrl+I insert row, Delete marks rows, Ctrl+C copies (TSV), context menu
  copy as CSV/JSON/INSERT, set NULL, set default.
- Staged changes: edited cells yellow, new rows green, deleted rows red with
  strike-through; Ctrl+S commits in one transaction, Ctrl+Shift+Delete
  discards; "Preview SQL" shows what will run.
- Query tab: editor with SQL highlighting (keywords, strings, comments,
  numbers) and line numbers; Ctrl+Enter runs the statement under the cursor
  or the selection; Ctrl+Shift+Enter runs all; results below in tabs, one
  per statement, with time and row count; errors shown inline; history and
  saved queries in a side drawer.
- Structure tab: columns grid (name, type, nullable, default, comment),
  indexes, foreign keys; edits stage like data edits and Ctrl+S shows the
  DDL for confirmation.
- Redis tab: key list (pattern, type badge, TTL), value pane per type,
  console for raw commands.
- Mongo tab: document grid (top-level fields as columns) or JSON view, filter
  box (JSON), sort, limit; edit a document in a JSON editor.

### Safe mode

Connections tagged production confirm before: commit, any statement that is
not a SELECT/SHOW/EXPLAIN/WITH-select, structure changes, drop/truncate.

## Error handling

- Every helper error has a code (`auth`, `network`, `tunnel`, `sql`,
  `notfound`, `readonly`, `drivers`, `internal`) and a human message; the
  window shows it in a toast or inline under the editor.
- A failed commit rolls back and leaves the staged changes in place.
- If the helper process dies, the window shows "Helper stopped" with a
  restart button; open tabs keep their state and reconnect.
- Driver install failure (offline, hash mismatch) shows the pip error and a
  Retry button; nothing partial is kept.

## Testing

- `tests/test-tablectl.sh` creates `zt-*` servers with OmaDB `dbctl` for
  each engine (native mode), then drives `tablectl` over its protocol:
  connect/auth failure, databases, tree, rows with sort/filter/paging,
  commit insert/update/delete and rollback on error, query run multiple
  statements, cancel, structure get/preview/apply, export/import round trip,
  Redis and Mongo operations, OmaDB import, keyring store/fallback.
- SSH test: tunnel to `127.0.0.1` via the local sshd if running, otherwise
  skipped with a message.
- Lock test: every pinned file hash matches; tampered hash refuses install.
- UI click tests with the scratchpad click helpers: open window, connect,
  edit a cell, Ctrl+S, run a query.

## Milestones

1. Helper bootstrap, protocol, connections store, keyring, welcome window.
2. SQL sessions with SSH tunnels, sidebar, data grid, staged edits and commit.
3. SQL editor, results, history, cancel.
4. Structure editing, export, CSV import.
5. Redis and MongoDB browsers.
6. Safe mode, tests, README, GitHub repo, marketplace
   submission.
