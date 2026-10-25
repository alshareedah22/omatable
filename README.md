# OmaTable

A TablePlus-style database GUI for [Omarchy](https://omarchy.org). Status: early (M2): connections, table
browsing and editing for PostgreSQL, MySQL/MariaDB and SQLite. The SQL editor, structure editing, export and the
Redis/MongoDB browsers come next.

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

| Shortcut | Action |
|---|---|
| Ctrl+S | Commit staged changes |
| Ctrl+Shift+Delete | Discard staged changes |
| Ctrl+I | Insert row |
| Ctrl+F | Add a filter |
| Ctrl+R / F5 | Reload |
| Ctrl+C | Copy cell |
| Ctrl+W, Ctrl+Tab | Close / cycle tabs |

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
