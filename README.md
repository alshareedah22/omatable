# OmaTable

A TablePlus-style database GUI for [Omarchy](https://omarchy.org). Status: early (M4): connections, table
browsing and editing, a SQL editor, structure editing, export and CSV import for PostgreSQL, MySQL/MariaDB and
SQLite. The Redis/MongoDB browsers come next.

- PostgreSQL, MySQL, MariaDB, SQLite, Redis, Valkey and MongoDB
- Servers from [OmaDB](https://github.com/alshareedah22/omadb) are listed automatically, with their credentials
- Passwords are kept in your keyring (Secret Service), never in plain files when a keyring is available
- SSH tunnels with agent, key or password login

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

## Install

Install from the Omarchy plugin manager, or:

    git clone https://github.com/alshareedah22/omatable ~/.config/omarchy/plugins/blackcode.omatable
    omarchy restart shell

Then add the **OmaTable** bar widget, or open the window with:

    omarchy-shell shell summon blackcode.omatable '{}'

The first launch installs the database drivers into `~/.local/share/omatable/venv`. Every wheel is pinned by
version and SHA-256 in `requirements.lock`; anything that does not match is refused.

## Files

- `~/.config/omatable/connections.json`: saved connections (mode 600)
- `~/.config/omatable/history.jsonl`, `queries.json`: query history (last 1,000 runs) and saved queries
  (mode 600, since SQL can contain secrets)
- `~/.local/share/omatable/venv`: the drivers

## Development

    /usr/bin/python3 -m unittest discover -s tests -t . -v                     # unit tests
    OMATABLE_TEST_NET=1 /usr/bin/python3 -m unittest discover -s tests -t . -v # plus driver install
    tools/update-requirements-lock                                              # bump drivers

Database tests need the OmaDB servers `zt-pg` (PostgreSQL) and `zt-my` (MariaDB) and the drivers' venv:

    OMATABLE_TEST_DB=1 ~/.local/share/omatable/venv/bin/python -m unittest discover -s tests -t . -v

SSH tests start a private, unprivileged `sshd` on a free port when `/usr/bin/sshd` exists.

## License

MIT
