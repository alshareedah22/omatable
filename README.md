# OmaTable

A TablePlus-style database GUI for [Omarchy](https://omarchy.org). Status: early (M1): connections management.

- PostgreSQL, MySQL, MariaDB, SQLite, Redis, Valkey and MongoDB
- Servers from [OmaDB](https://github.com/alshareedah22/omadb) are listed automatically, with their credentials
- Passwords are kept in your keyring (Secret Service), never in plain files when a keyring is available
- SSH tunnels with agent, key or password login

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

    /usr/bin//usr/bin/python3 -m unittest discover -s tests -t . -v  # unit tests
    OMATABLE_TEST_NET=1 /usr/bin/python3 -m unittest discover -s tests -t . -v   # plus driver install
    tools/update-requirements-lock                          # bump drivers

## License

MIT
