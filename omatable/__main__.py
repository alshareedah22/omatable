"""Entry point: `python -m omatable` serves the protocol on stdin/stdout."""

from . import __version__, omadb
from .protocol import Server
from .store import Store


def build(store, server=None):
    server = server or Server()

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

    return server


def main():
    server = build(Store())
    server.event("ready", version=__version__)
    server.serve()


if __name__ == "__main__":
    main()
