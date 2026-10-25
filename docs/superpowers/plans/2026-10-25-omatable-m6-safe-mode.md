# OmaTable M6: safe mode, discard prompts, release

**Goal:** Production connections confirm before anything that changes data; staged edits are never dropped
silently; version 1.0.0 with README, preview and a marketplace submission.

**Spec:** `docs/superpowers/specs/2026-10-25-omatable-design.md` (Safe mode)

## Design

- The helper enforces it: every write method takes `confirmed`; on a production connection without it the
  reply is error `confirm` with the question and the exact SQL/command in `detail`.
- `omatable/safety.py` classifies SQL by its words outside strings/comments (SELECT/SHOW/EXPLAIN/plain WITH
  read; `WITH … DELETE`, `EXPLAIN ANALYZE UPDATE`, `SELECT … INTO` write), MongoDB commands by a read-only list
  (plus `$out`/`$merge` pipelines); Redis asks the server (`COMMAND INFO` flags write/may_replicate/admin, with
  read-only admin subcommands such as `CONFIG GET` allowed).
- `Helper.qml` answers `confirm` errors through one prompt in `Panel.qml` and resends with `confirmed: true`;
  dialogs that already asked (drop, truncate, structure apply, deletes) send it themselves.
- Closing a dirty tab, switching databases or disconnecting asks to discard staged changes.

### Tasks
- [x] Safety rules + tests (`tests/test_safety.py`); protocol guard + session tests (SQLite, live Valkey, MongoDB).
- [x] Window: central production prompt, discard prompts; click-tested on a production PostgreSQL connection.
- [x] 1.0.0, README (safe mode, requirements, removal), preview; merge.
- [ ] Marketplace submission (after the user approves posting it).
