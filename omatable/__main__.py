"""Entry point: `python -m omatable` serves the protocol on stdin/stdout."""

import signal
import sys

from . import __version__, omadb
from .protocol import Server
from .session import Sessions
from .store import Store


def build(store, server=None, sessions=None):
    server = server or Server()
    sessions = sessions or Sessions(store)
    server.sessions = sessions

    @server.method("app.version")
    def version():
        return {"version": __version__}

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
