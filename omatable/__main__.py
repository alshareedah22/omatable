"""Entry point: `python -m omatable` serves the protocol on stdin/stdout."""

import os
import re
import signal
import sys
import tomllib

from . import __version__, omadb, sqlsplit
from .history import History, Saved
from .protocol import Error, Server
from .session import Sessions
from .store import Store

DDL = ("CREATE", "DROP", "ALTER", "RENAME")
# Editor colour role -> colors.toml keys to try, in order.
PALETTE = {"keyword": ("magenta", "color5"), "string": ("green", "color2"), "number": ("yellow", "color3"),
           "comment": ("dark_foreground", "color8"), "identifier": ("cyan", "color6")}
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")


def palette():
    path = os.environ.get("OMATABLE_THEME_COLORS") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "omarchy", "current", "theme", "colors.toml")
    try:
        with open(path, "rb") as f:
            colors = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    out = {}
    for role, keys in PALETTE.items():
        for key in keys:
            value = colors.get(key)
            if isinstance(value, str) and HEX.match(value):
                out[role] = value
                break
    return out


def build(store, server=None, sessions=None):
    server = server or Server()
    sessions = sessions or Sessions(store)
    server.sessions = sessions
    history = History(store.dir)
    saved = Saved(store.dir)

    @server.method("app.version")
    def version():
        return {"version": __version__}

    @server.method("app.palette")
    def app_palette():
        return palette()

    @server.method("conn.list")
    def conn_list():
        return {"connections": store.list(), "omadb": omadb.servers(), "keyring": store.ring.available()}

    @server.method("conn.save")
    def conn_save(conn):
        return store.save(conn)

    @server.method("conn.delete")
    def conn_delete(id):  # noqa: A002 - protocol field name
        store.delete(id)
        return {"ok": True}

    @server.method("conn.duplicate")
    def conn_duplicate(id):  # noqa: A002
        return store.duplicate(id)

    @server.method("conn.import_omadb")
    def conn_import_omadb(name, conn):
        source = omadb.server(name)
        merged = {**conn, "password": conn["password"] if "password" in conn else source["password"]}
        merged.pop("omadb", None)
        merged.pop("id", None)
        return store.save(merged)

    @server.method("conn.test")
    def conn_test(conn):
        return sessions.test(conn)

    @server.method("session.open")
    def session_open(id):  # noqa: A002
        return sessions.open(id)

    @server.method("session.close")
    def session_close(session):
        sessions.close(session)
        return {"ok": True}

    @server.method("session.databases")
    def session_databases(session):
        s = sessions.get(session)
        return {"databases": s.run(s.adapter.databases), "database": s.adapter.database}

    @server.method("session.use")
    def session_use(session, database):
        s = sessions.get(session)
        s.run(s.adapter.use, database)
        return {"database": s.adapter.database}

    @server.method("schema.tree")
    def schema_tree(session):
        s = sessions.get(session)
        return {"schemas": s.run(s.adapter.tree), "database": s.adapter.database}

    @server.method("table.rows")
    def table_rows(session, schema, table, offset=0, limit=300, sort=None, filters=None, match="and"):
        s = sessions.get(session)
        return s.run(s.adapter.rows, schema, table, offset, limit, sort or [], filters or [], match)

    @server.method("table.count")
    def table_count(session, schema, table, filters=None, match="and"):
        s = sessions.get(session)
        return s.run(s.adapter.count, schema, table, filters or [], match)

    @server.method("table.preview")
    def table_preview(session, schema, table, changes):
        s = sessions.get(session)
        return s.run(s.adapter.preview, schema, table, changes)

    @server.method("table.commit")
    def table_commit(session, schema, table, changes):
        s = sessions.get(session)
        return s.run(s.adapter.commit, schema, table, changes)

    @server.method("query.run")
    def query_run(session, text, cursor=None):
        s = sessions.get(session)
        engine = s.conn.get("engine")
        text = str(text or "")
        if cursor is None:
            stmts = sqlsplit.split(text, engine)
        else:
            one = sqlsplit.at(text, sqlsplit.from_utf16(text, int(cursor)), engine)
            stmts = [one] if one else []
        if not stmts:
            raise Error("invalid", "There is no SQL to run")
        out = s.run(s.adapter.run, [sql for _, _, sql in stmts])
        ddl = any(sqlsplit.keyword(sql) in DDL for _, _, sql in stmts)
        if ddl:
            s.run(s.adapter.forget)
        results = out["results"]
        err = results[-1].get("error") if results else None
        start, end = stmts[0][0], stmts[-1][1]
        history.add({"conn": s.conn.get("id"), "name": s.conn.get("name"), "engine": engine,
                     "database": out["database"], "sql": text[start:end].strip(), "ok": err is None,
                     "error": err["message"] if err else None, "ms": sum(r["ms"] for r in results),
                     "statements": len(stmts)})
        return {**out, "ddl": ddl, "range": [sqlsplit.to_utf16(text, start), sqlsplit.to_utf16(text, end)]}

    @server.method("query.cancel")
    def query_cancel(session):
        sessions.get(session).cancel()
        return {"ok": True}

    @server.method("query.history")
    def query_history(conn=None, search="", limit=200):
        return {"items": history.list(conn, search, limit)}

    @server.method("query.history_clear")
    def query_history_clear(conn=None):
        history.clear(conn)
        return {"ok": True}

    @server.method("query.save")
    def query_save(name, sql, id=None):  # noqa: A002
        return saved.save(name, sql, id)

    @server.method("query.saved")
    def query_saved():
        return {"items": saved.list()}

    @server.method("query.delete_saved")
    def query_delete_saved(id):  # noqa: A002
        saved.delete(id)
        return {"ok": True}

    return server


def main():
    server = build(Store())
    # The window stops us with SIGTERM; exit through the finally so tunnels close.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server.event("ready", version=__version__)
    try:
        server.serve()
    finally:
        server.sessions.close_all()


if __name__ == "__main__":
    main()
