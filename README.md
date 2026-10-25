# OmaTable

A TablePlus-style database GUI for [Omarchy](https://omarchy.org): connections, table browsing and editing, a
SQL editor, structure editing, export and CSV import for PostgreSQL, MySQL/MariaDB and SQLite, a key browser for
Redis/Valkey and a document browser for MongoDB.

![OmaTable browsing a MongoDB collection](preview.png)

- PostgreSQL, MySQL, MariaDB, SQLite, Redis, Valkey and MongoDB
- Servers from [OmaDB](https://github.com/alshareedah22/omadb) are listed automatically, with their credentials
- Passwords are kept in your keyring (Secret Service), never in plain files when a keyring is available
- SSH tunnels with agent, key or password login
- Safe mode: connections tagged **production** ask before anything that changes data

## Using it

- Double-click a connection (or select it and press **Connect**). **Test** tries the form as typed.
- Pick a table in the sidebar; each table opens in a tab. Switch databases from the title bar.
- Click a column header to sort (Shift+click adds a column), **+ Filter** (Ctrl+F) to filter.
- Double-click, Enter or just start typing to edit a cell; Tab moves to the next one. Right-click for
  Set NULL, copy and row actions.
- Ctrl+I inserts a row, Delete marks the selected row for deletion.
- Edits are staged: changed cells turn yellow, new rows green, deleted rows red. **Preview SQL** shows the
  statements, Ctrl+S commits them in one transaction, Ctrl+Shift+Delete discards them. If any statement fails
  or a row no longer matches, nothing is saved and your edits stay on screen.
- Tables without a primary key (or unique not-null key) are read-only, except in SQLite, where rows are edited
  by their rowid.

### Safe mode

Tag a connection **production** (in its form) and OmaTable asks before it changes anything there: committing
edits, statements other than `SELECT`/`SHOW`/`EXPLAIN`/plain `WITH` queries, structure changes, imports,
truncate and drop, Redis commands the server marks as writes (`SET`, `DEL`, `FLUSHALL`, `CONFIG SET`, `EVAL`,
…), and MongoDB inserts, edits, deletes, index changes, `$out`/`$merge` pipelines and commands that are not
read-only. The prompt shows the exact SQL or command; Cancel leaves everything as it was. Reads never ask. The
check runs in the helper, so no button can skip it, and it leans towards asking when unsure.

Closing a tab, switching databases or leaving a connection with staged changes asks whether to discard them.
Hiding the window ends the session, so commit before you hide it.

### SQL editor

- **+ Query** (Ctrl+T) opens a query tab. Ctrl+Enter runs the statement under the cursor, or the selection;
  Ctrl+Shift+Enter runs everything.
- Each statement gets its own result tab with its row count and time. A run stops at the first error and
  keeps the results before it. Results show up to 1,000 rows each; click a header to sort them.
- **■ Cancel** (Ctrl+.) stops a running query.
- **History** (Ctrl+H) lists what you ran on this connection, searchable; click an entry to load it.
  **Save** (Ctrl+S) keeps a query under a name in the **Saved** list.
- `CREATE`/`DROP`/`ALTER` refresh the sidebar, and MySQL `USE` switches the database.

### Structure, export and import

- **Structure** (the switch under a table, or right-click → Structure) lists columns, indexes, foreign keys and
  the table's DDL. Rename columns, change type, NULL rule, default (as SQL, e.g. `0`, `'none'`, `now()`) or
  comment, add and drop columns and indexes, drop foreign keys. Changes are staged; Ctrl+S shows the SQL and
  applies it after you confirm.
  - PostgreSQL and SQLite apply all of it in one transaction. MySQL commits each statement on its own, so a
    failure there says how many statements already ran.
  - SQLite can only rename, add and drop columns; changing a type means recreating the table.
- **Export** (under a table, on a query result, or right-click → Export…) writes CSV, JSON or SQL `INSERT`s. A
  table export respects the current filters and sort; a result export runs that statement again and saves all
  its rows. Files are written atomically, readable only by you, and never over an existing file unless you
  say Replace.
- **Import CSV…** (right-click a table) reads the file, guesses the delimiter, maps CSV columns to table columns
  by name (change any mapping or skip a column) and inserts every row in one transaction: one bad row and
  nothing is imported, with the line numbers in the error.
- Right-click a table for **Truncate…** and **Drop…**; both ask first. Right-click a cell to copy the row as
  TSV, JSON or an `INSERT`.

### Redis and Valkey

- Keys are listed with SCAN: type a pattern (`user:*`) and press Enter, or pick a type. **Load more** keeps
  scanning big databases. Each key shows its type and time to live.
- The value pane fits the type: a text editor for strings (**Format JSON**, Ctrl+S saves), tables for hashes,
  lists, sets, sorted sets and streams. Double-click an item (or hover it for ✎ and ✕) to change or remove it,
  **+ Field / Push / Member / Entry** to add one. Collections show their first 1,000 items.
- List edits check the item is still the one you saw, so a concurrent change is refused instead of
  overwriting the wrong position.
- **Rename**, **Set TTL…** (or remove the expiry) and **Delete** act on the key; deleting asks first.
  **+ Key** (Ctrl+N) creates one of any type.
- Binary keys and values are shown with `\xHH` escapes and are written back byte for byte.
- **Console** (Ctrl+`) runs any command with redis-cli style replies and Up/Down history. Commands that
  would block the connection (SUBSCRIBE, MONITOR, BLPOP, …) are refused; `SELECT n` switches the browser.

### MongoDB

- Collections and views are on the left (right-click to drop, **+** for a new collection).
- **Find** takes a filter, sort and field list in mongosh syntax: `{age: {$gt: 30}, city: 'Riyadh'}`,
  `{_id: ObjectId('…')}`, `{joined: {$gte: ISODate('2025-01-01')}}`, `/regex/i`. Plain JSON and Extended JSON
  work too. Click a column header to sort on the server. Pages hold 50 to 1,000 documents.
- **Aggregate** runs a pipeline (Ctrl+Enter); results are read-only.
- **Documents** shows top-level fields as columns; **JSON** shows whole documents. Double-click or **Edit**
  opens a document in the JSON editor (Ctrl+S saves the whole document; the `_id` cannot change).
  **+ Insert** (Ctrl+I) takes one document or a list; right-click a row to duplicate it or copy it.
- **Indexes** lists, creates (`{email: 1}`, unique or not) and drops indexes.
- **Console** runs database commands such as `{dbStats: 1}` or `{count: 'orders'}`.
- Views are read-only. Finds and aggregations stop after 60 seconds.
- Users sign in against the `admin` database (where OmaDB and most installs create them); `mongodb+srv://`
  URLs are not supported yet.

| Shortcut | Action |
|---|---|
| Ctrl+S | Commit staged changes |
| Ctrl+Shift+Delete | Discard staged changes |
| Ctrl+I | Insert row |
| Ctrl+F | Add a filter |
| Ctrl+R / F5 | Reload |
| Ctrl+C | Copy cell |
| Ctrl+W, Ctrl+Tab | Close / cycle tabs |
| Ctrl+T | New query tab |
| Ctrl+Enter | Run statement at cursor (or selection) |
| Ctrl+Shift+Enter | Run all statements |
| Ctrl+. | Cancel the running query |
| Ctrl+S (query tab) | Save the query |
| Ctrl+H | History and saved queries |
| Ctrl+` | Redis / MongoDB console |
| Ctrl+N | New Redis key |

## Install

Install from the Omarchy plugin manager, or:

    git clone https://github.com/alshareedah22/omatable ~/.config/omarchy/plugins/blackcode.omatable
    omarchy restart shell

Then add the **OmaTable** bar widget, or open the window with:

    omarchy-shell shell summon blackcode.omatable '{}'

The first launch installs the database drivers into `~/.local/share/omatable/venv`. Every wheel is pinned by
version and SHA-256 in `requirements.lock`; anything that does not match is refused.

## Requirements

Omarchy with Python 3 (for the helper and its venv), `wl-copy` for copying, `ssh` for tunnels, and a Secret
Service keyring (GNOME Keyring or KeePassXC) to keep passwords out of plain files. The drivers (psycopg, PyMySQL,
redis-py, pymongo) come from PyPI on first launch, pinned by hash. [OmaDB](https://github.com/alshareedah22/omadb)
is optional.

## Remove

    omarchy plugin remove blackcode.omatable
    rm -rf ~/.config/omatable ~/.local/share/omatable   # saved connections, history and the drivers

Saved passwords live in your keyring as "OmaTable … password" items; delete a connection in the app first, or
clear them all with `secret-tool clear app omatable`. OmaTable never changes your databases' files or OmaDB's servers.

## Files

- `~/.config/omatable/connections.json`: saved connections (mode 600)
- `~/.config/omatable/history.jsonl`, `queries.json`: query history (last 1,000 runs) and saved queries
  (mode 600, since SQL can contain secrets)
- `~/.local/share/omatable/venv`: the drivers

## Development

    /usr/bin/python3 -m unittest discover -s tests -t . -v                     # unit tests
    OMATABLE_TEST_NET=1 /usr/bin/python3 -m unittest discover -s tests -t . -v # plus driver install
    tools/update-requirements-lock                                              # bump drivers

Database tests need the OmaDB servers `zt-pg` (PostgreSQL 17), `zt-my` (MariaDB), `zt-vk` (Valkey 9),
`zt-rd` (Redis 8) and `zt-mg` (MongoDB 8, user `dev`), and the drivers' venv:

    OMATABLE_TEST_DB=1 ~/.local/share/omatable/venv/bin/python -m unittest discover -s tests -t . -v

SSH tests start a private, unprivileged `sshd` on a free port when `/usr/bin/sshd` exists.

## License

MIT
