"""SQLite through the standard library. Keyless tables are edited by rowid."""

import os
import sqlite3
import urllib.parse

from ..protocol import Error
from .base import SQLAdapter

SCHEMA = "main"


class SQLite(SQLAdapter):
    engine = "sqlite"

    def connect(self):
        path = os.path.expanduser(self.conn.get("path") or "")
        if not os.path.isfile(path):
            raise Error("notfound", f"no SQLite file at {path}")
        uri = "file:" + urllib.parse.quote(os.path.abspath(path)) + "?mode=rw"
        with self.guard():
            self.db = sqlite3.connect(uri, uri=True, check_same_thread=False, isolation_level=None, timeout=5)
            self.db.execute("SELECT 1 FROM sqlite_master LIMIT 1")
        self.database = SCHEMA

    def translate(self, exc):
        if isinstance(exc, sqlite3.DatabaseError) and "not a database" in str(exc):
            return Error("invalid", "this file is not a SQLite database")
        return None

    def version(self):
        return "SQLite " + sqlite3.sqlite_version

    def databases(self):
        return [SCHEMA]

    def use(self, database):
        if database != SCHEMA:
            raise Error("notfound", f"database {database!r} not found")

    def tree(self):
        self.forget()
        _, rows = self.query("SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') "
                             "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
        return [{"name": SCHEMA, "tables": [n for n, t in rows if t == "table"],
                 "views": [n for n, t in rows if t == "view"], "functions": [], "sequences": []}]

    def _kind(self, table):
        _, rows = self.query("SELECT type FROM sqlite_master WHERE name = ?", (table,))
        return rows[0][0] if rows else None

    def load_columns(self, schema, table):
        _, rows = self.query(f"PRAGMA {self.d.quote(schema)}.table_info({self.d.quote(table)})")
        return [{"name": name, "type": typ or "", "nullable": not notnull, "default": dflt, "pk": pk}
                for _, name, typ, notnull, dflt, pk in rows]

    def key(self, schema, table):
        pk = sorted((c for c in self.columns(schema, table) if c["pk"]), key=lambda c: c["pk"])
        return [c["name"] for c in pk]

    def row_extra(self, schema, table, key):
        if key or self._kind(table) != "table":
            return "", (), {}
        try:
            self.query(f"SELECT rowid FROM {self.d.table(schema, table)} LIMIT 0")
        except Error:  # WITHOUT ROWID
            return "", (), {}
        return "rowid AS __rowid, ", ("__rowid",), {"__rowid": "rowid"}
