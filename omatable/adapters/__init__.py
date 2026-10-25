"""One adapter per engine; `create(conn)` picks it."""

from ..protocol import Error


def create(conn):
    engine = conn.get("engine")
    if engine == "postgresql":
        from .postgres import Postgres
        return Postgres(conn)
    if engine in ("mysql", "mariadb"):
        from .mysql import MySQL
        return MySQL(conn)
    if engine == "sqlite":
        from .sqlite import SQLite
        return SQLite(conn)
    if engine in ("redis", "valkey"):
        from .redis import Redis
        return Redis(conn)
    if engine == "mongodb":
        from .mongo import Mongo
        return Mongo(conn)
    raise Error("invalid", f"unknown engine {engine!r}")
