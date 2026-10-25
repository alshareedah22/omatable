"""What every SQL engine shares: paging, counting and committing grid edits.

Engines supply connect/close, the catalog queries (databases, tree, columns,
key) and an error translator; this class runs the sqlgen statements. One
adapter is used by one thread at a time (its session's worker).
"""

import contextlib
import math
import time

from .. import sqlgen
from ..protocol import Error


class SQLAdapter:
    engine = ""

    def __init__(self, conn):
        self.conn = conn
        self.database = conn.get("database") or ""
        self.d = sqlgen.dialect(conn.get("engine") or self.engine)
        self.db = None
        self._columns = {}

    # engine hooks ---------------------------------------------------------
    def connect(self):
        raise NotImplementedError

    def translate(self, exc):
        """Map a driver exception to an Error, or return None."""
        return None

    def version(self):
        return ""

    def databases(self):
        return []

    def use(self, database):
        raise Error("invalid", "this engine has no databases to switch")

    def tree(self):
        raise NotImplementedError

    def load_columns(self, schema, table):
        raise NotImplementedError

    def key(self, schema, table):
        """Columns that identify one row: the primary key, else a unique not-null key, else []."""
        return []

    def row_extra(self, schema, table, key):
        """Extra select list prefix, hidden column names and raw key SQL (sqlite rowid)."""
        return "", (), {}

    # shared ---------------------------------------------------------------
    @contextlib.contextmanager
    def guard(self):
        try:
            yield
        except Error:
            raise
        except Exception as e:  # noqa: BLE001 - translated or re-raised as a SQL error
            err = self.translate(e)
            raise (err or Error("sql", str(e).strip() or type(e).__name__)) from e

    def close(self):
        if self.db is not None:
            with contextlib.suppress(Exception):
                self.db.close()
            self.db = None

    def query(self, sql, params=()):
        with self.guard():
            cur = self.db.cursor()
            try:
                cur.execute(sql, params)
                names = [c[0] for c in cur.description or ()]
                return names, [list(r) for r in cur.fetchall()] if cur.description else []
            finally:
                cur.close()

    def columns(self, schema, table, refresh=False):
        cache = (schema, table)
        if refresh or cache not in self._columns:
            cols = self.load_columns(schema, table)
            if not cols:
                raise Error("notfound", f"table {table!r} not found")
            self._columns[cache] = cols
        return self._columns[cache]

    def forget(self):
        self._columns.clear()

    @staticmethod
    def clean(value):
        if isinstance(value, float) and not math.isfinite(value):
            return str(value)
        return value

    def rows(self, schema, table, offset=0, limit=300, sort=(), filters=(), match="and"):
        cols = self.columns(schema, table, refresh=offset == 0 and not sort and not filters)
        names = [c["name"] for c in cols]
        key = self.key(schema, table)
        extra, hidden, raw = self.row_extra(schema, table, key)
        if raw:
            key = list(raw)
        sql, params = sqlgen.select(self.d, schema, table, names, sort, filters, match, limit, offset, extra)
        start = time.monotonic()
        got, rows = self.query(sql, params)
        info = {c["name"]: c for c in cols}
        return {
            "columns": [{"name": n, "type": info.get(n, {}).get("type", ""), "pk": n in key,
                         "nullable": info.get(n, {}).get("nullable", True),
                         "default": info.get(n, {}).get("default"), "hidden": n in hidden} for n in got],
            "rows": [[self.clean(v) for v in r] for r in rows],
            "key": key, "editable": bool(key), "offset": max(0, int(offset)), "limit": int(limit),
            "ms": round((time.monotonic() - start) * 1000),
        }

    def count(self, schema, table, filters=(), match="and"):
        names = [c["name"] for c in self.columns(schema, table)]
        sql, params = sqlgen.count(self.d, schema, table, names, filters, match)
        return {"count": self.query(sql, params)[1][0][0]}

    def statements(self, schema, table, changes):
        names = [c["name"] for c in self.columns(schema, table)]
        key = self.key(schema, table)
        _, _, raw = self.row_extra(schema, table, key)
        if raw:
            key = list(raw)
        return sqlgen.changes(self.d, schema, table, names, key, changes or {}, raw)

    def preview(self, schema, table, changes):
        return {"statements": [sqlgen.render(self.d, sql, params) + ";"
                               for sql, params, _ in self.statements(schema, table, changes)]}

    def commit(self, schema, table, changes):
        stmts = self.statements(schema, table, changes)
        if not stmts:
            return {"affected": 0}
        cur = self.db.cursor()
        affected = 0
        with self.guard():
            try:
                cur.execute("BEGIN")
                for sql, params, expect_one in stmts:
                    cur.execute(sql, params)
                    n = cur.rowcount
                    if expect_one and n != 1:
                        raise Error("sql", f"{'No row' if n == 0 else f'{n} rows'} matched "
                                           f"{sqlgen.render(self.d, sql, params)}; nothing was saved")
                    affected += max(n, 0)
                cur.execute("COMMIT")
            except BaseException:
                with contextlib.suppress(Exception):
                    cur.execute("ROLLBACK")
                raise
            finally:
                cur.close()
        return {"affected": affected}
