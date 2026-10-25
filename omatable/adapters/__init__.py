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
    raise Error("invalid", f"{engine} connections open in their own browser, not the SQL workspace")
