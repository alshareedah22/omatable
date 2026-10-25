# OmaTable M5: Redis/Valkey and MongoDB browsers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open Redis/Valkey and MongoDB connections in their own browsers: a Redis key list with typed value editors, TTLs and a command console; a MongoDB collection browser with a document grid, JSON view and editor, filters in shell syntax, indexes and a command runner.

**Architecture:** Two new adapters (`adapters/redis.py`, `adapters/mongo.py`) behind the same `Session` (worker thread, SSH tunnel, `info()`). A small `mongojs` module turns mongosh-style input (`{age: {$gt: 30}}`, `ObjectId("…")`, `ISODate("…")`) into Extended JSON. The window picks `RedisBrowser` or `MongoBrowser` instead of `Workspace` by engine; the title strip moves into a shared `TitleBar`.

**Tech Stack:** redis-py 8.1, pymongo 4.19 (already pinned in `requirements.lock`); Quickshell/QtQuick.

**Spec:** `docs/superpowers/specs/2026-10-25-omatable-design.md`

## Global Constraints

- Redis keys and values that are not UTF-8 cross the wire as `{"$t": "bytes", "v": base64}` and are written back byte for byte.
- Redis list edits are checked against the value the window saw (a Lua script compares `LINDEX` first), so a concurrent change is refused instead of overwriting the wrong item.
- Blocking or connection-changing console commands (SUBSCRIBE, MONITOR, …) are refused; `SELECT` in the console switches the browser's database.
- MongoDB documents are edited as relaxed Extended JSON; `_id` values are sent back in canonical Extended JSON so the match is exact. Changing `_id` in the editor is refused.
- Large values are capped: Redis collections show the first 1,000 items, strings the first 1 MB (read-only when cut); Mongo pages hold at most 1,000 documents; finds and aggregations stop after 60 s (`maxTimeMS`).
- Deleting keys, documents, collections or indexes always asks first.
- Tests: venv python `-m unittest discover -s tests -t .`; live tests need OmaDB `zt-vk` (Valkey 9), `zt-rd` (Redis 8), `zt-mg` (MongoDB 8, user dev) and `OMATABLE_TEST_DB=1`.

---

## Interfaces

### `adapters/redis.py` — `Redis(conn)`
`connect`, `close`, `version`, `databases`, `use(db)`, `cancel` (no-op), and
- `scan(pattern="*", cursor="0", count=500, type=None) -> {"keys": [{"key", "type", "ttl"}], "cursor", "total"}`
- `get(key, limit=1000) -> {"key", "type", "ttl", "size", "value", "truncated", "editable"}`; value per type: string → str|bytes-tag; hash → `[[field, value]]`; list/set → `[value]`; zset → `[[member, score]]`; stream → `[{"id", "fields": [[f, v]]}]`.
- `create(key, type, value, ttl=None)` (refuses an existing key), `edit(key, type, action, item=None, value=None, score=None, old=None)`, `delete(keys)`, `rename(key, new)`, `expire(key, ttl)` (`None`/negative = persist), `command(text) -> {"reply", "database", "ms"}`.

### `omatable/mongojs.py`
- `parse(text, what="filter")` → Python/BSON value; empty → `{}`. Accepts JSON, Extended JSON and mongosh syntax (unquoted keys, single quotes, `ObjectId`, `ISODate`, `new Date`, `NumberLong`, `NumberInt`, `NumberDecimal`, `/re/flags`, trailing commas).
- `dumps(value, indent=None)` relaxed EJSON; `cell(value)` grid display value.

### `adapters/mongo.py` — `Mongo(conn)`
`connect`, `close`, `version`, `databases`, `use`, `tree` (collections and views), and
- `find(collection, filter="", sort="", projection="", skip=0, limit=100) -> {"columns", "rows", "docs", "ids", "skip", "limit", "ms"}`
- `aggregate(collection, pipeline, limit=100)` (same shape), `count(collection, filter="")`
- `insert(collection, text)`, `update(collection, id, text)`, `delete(collection, ids)`
- `indexes(collection)`, `create_index(collection, keys, unique=False, name="")`, `drop_index(collection, name)`
- `create_collection(name)`, `drop_collection(name)`, `command(text) -> {"reply": text, "ms"}`

### Protocol
`redis.scan`, `redis.get`, `redis.create`, `redis.edit`, `redis.del`, `redis.rename`, `redis.ttl`, `redis.cmd`;
`mongo.find`, `mongo.aggregate`, `mongo.count`, `mongo.insert`, `mongo.update`, `mongo.delete`, `mongo.indexes`, `mongo.create_index`, `mongo.drop_index`, `mongo.create_collection`, `mongo.drop_collection`, `mongo.run`.
A method called on the wrong kind of session fails with `invalid`.

### QML
`TitleBar.qml` (shared), `RedisBrowser.qml`, `RedisValue.qml`, `MongoBrowser.qml`, `MongoModel.qml`, `JsonEditor.qml`; `Panel.qml` picks the browser by engine; `DataGrid` takes custom menu items from its model.

---

### Task 1: Redis adapter
**Files:** Create `omatable/adapters/redis.py`; Modify `adapters/__init__.py`; Test `tests/test_redis.py`
- [ ] Live tests on Valkey and Redis: version/databases/use; scan with pattern, type filter and cursor paging; get each type (incl. binary key and value, truncation); create refuses existing; edits per type incl. stale list edit refused; delete, rename refuses existing target, expire/persist; command reply shapes, quoting, refused SUBSCRIBE, SELECT switches database.
- [ ] Implement, commit "Add the Redis and Valkey adapter".

### Task 2: MongoDB adapter
**Files:** Create `omatable/mongojs.py`, `omatable/adapters/mongo.py`; Test `tests/test_mongojs.py`, `tests/test_mongo.py`
- [ ] Unit tests for `mongojs.parse` (shell syntax, EJSON, errors with position) and `cell`.
- [ ] Live tests: databases/tree; find with filter/sort/projection/paging and column union; aggregate; count; insert one/many; update round trip keeps types, refuses `_id` change and missing doc; delete; indexes create/drop (refuse `_id_`); collection create/drop; command.
- [ ] Implement, commit "Add the MongoDB adapter".

### Task 3: Protocol methods
**Files:** Modify `omatable/__main__.py`; Test `tests/test_session.py`
- [ ] Live tests through `build()` for a few redis.* and mongo.* calls and the wrong-engine error; commit "Add Redis and MongoDB protocol methods".

### Task 4: Window
**Files:** Create the QML files above; Modify `Panel.qml`, `Workspace.qml`, `DataGrid.qml`
- [ ] Redis browser: database picker with key counts, pattern + type filter, key list (type badge, TTL, load more), value pane per type with add/edit/delete items, rename, TTL, delete key, new key dialog, console with history.
- [ ] Mongo browser: collection list (new/drop), filter/sort/projection bar, Find/Aggregate, paging with count, grid and JSON views, JSON editor for edit/insert/duplicate, delete selected, indexes page, command runner.
- [ ] Click test on zt-vk and zt-mg; commit "Add the Redis and MongoDB browsers".

### Task 5: Docs and merge
- [ ] README, tick plan, full tests, merge to `main`.
