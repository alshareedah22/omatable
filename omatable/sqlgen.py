"""SQL for the data grid, per dialect.

Identifiers are quoted by the dialect and must be one of the table's real
columns; values are always bound as parameters. `render` inlines literals
for the "Preview SQL" view only, never for execution.
"""

import base64
import datetime
import json
import math
import re

from .protocol import Error

MAX_LIMIT = 10000
OPS = ("=", "<>", "<", ">", "<=", ">=", "contains", "not_contains", "starts", "ends", "in", "null", "not_null")
COMPARE = ("=", "<>", "<", ">", "<=", ">=")


class Dialect:
    def __init__(self, name, quote_char, mark, ilike=False, escape="'\\'", default_values="DEFAULT VALUES"):
        self.name = name
        self.default_values = default_values
        self.quote_char = quote_char
        self.mark = mark
        self.ilike = ilike
        self.escape = escape

    def quote(self, name):
        q = self.quote_char
        return q + str(name).replace(q, q + q) + q

    def finish(self, sql):
        """SQL about to run with parameters: a literal % (in a quoted name) must be %%."""
        return re.sub(r"%(?!s)", "%%", sql) if self.mark == "%s" else sql

    def table(self, schema, name):
        return (self.quote(schema) + "." if schema else "") + self.quote(name)

    def like(self, column, negate=False):
        if self.ilike:
            expr, op = f"CAST({column} AS TEXT)", "ILIKE"
        else:
            expr, op = column, "LIKE"
        return f"{expr} {'NOT ' if negate else ''}{op} {self.mark} ESCAPE {self.escape}"


DIALECTS = {
    "postgresql": Dialect("postgresql", '"', "%s", ilike=True),
    "mysql": Dialect("mysql", "`", "%s", escape="'\\\\'", default_values="() VALUES ()"),
    "sqlite": Dialect("sqlite", '"', "?"),
}


def dialect(engine):
    d = DIALECTS.get("mysql" if engine == "mariadb" else engine)
    if d is None:
        raise Error("invalid", f"{engine} is not a SQL engine")
    return d


def decode(value):
    """Undo protocol.encode for values coming back from the window."""
    if isinstance(value, dict) and value.get("$t") == "bytes":
        return base64.b64decode(value.get("v") or "")
    return value


def _column(columns, name):
    if name not in columns:
        raise Error("invalid", f"unknown column {name!r}")
    return name


def _like_value(value):
    return str(value).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def where(d, columns, filters, match="and"):
    parts, params = [], []
    for f in filters or ():
        col = d.quote(_column(columns, f.get("column")))
        op = f.get("op")
        value = decode(f.get("value"))
        if op in COMPARE:
            parts.append(f"{col} {op} {d.mark}")
            params.append(value)
        elif op in ("contains", "not_contains"):
            parts.append(d.like(col, negate=op == "not_contains"))
            params.append("%" + _like_value(value) + "%")
        elif op == "starts":
            parts.append(d.like(col))
            params.append(_like_value(value) + "%")
        elif op == "ends":
            parts.append(d.like(col))
            params.append("%" + _like_value(value))
        elif op == "in":
            items = [v.strip() for v in str(value).split(",") if v.strip()]
            if not items:
                raise Error("invalid", "IN needs at least one value")
            parts.append(f"{col} IN ({', '.join([d.mark] * len(items))})")
            params.extend(items)
        elif op == "null":
            parts.append(f"{col} IS NULL")
        elif op == "not_null":
            parts.append(f"{col} IS NOT NULL")
        else:
            raise Error("invalid", f"unknown operator {op!r}")
    if not parts:
        return "", []
    joiner = " OR " if match == "or" else " AND "
    return " WHERE " + joiner.join(parts), params


def select(d, schema, table, columns, sort=(), filters=(), match="and", limit=300, offset=0, extra=""):
    cond, params = where(d, columns, filters, match)
    sql = f"SELECT {extra}* FROM {d.table(schema, table)}{cond}"
    order = [f"{d.quote(_column(columns, s.get('column')))} {'DESC' if s.get('desc') else 'ASC'}"
             for s in sort or ()]
    if order:
        sql += " ORDER BY " + ", ".join(order)
    sql += f" LIMIT {d.mark} OFFSET {d.mark}"
    return sql, params + [max(1, min(int(limit), MAX_LIMIT)), max(0, int(offset))]


def select_all(d, schema, table, columns, sort=(), filters=(), match="and", extra=""):
    """Every matching row, for exports; no LIMIT."""
    sql, params = select(d, schema, table, columns, sort, filters, match, 1, 0, extra)
    return sql[:sql.rindex(" LIMIT ")], params[:-2]


def count(d, schema, table, columns, filters=(), match="and"):
    cond, params = where(d, columns, filters, match)
    return f"SELECT COUNT(*) FROM {d.table(schema, table)}{cond}", params


def _key_where(d, key, row_key, raw_keys):
    # raw_keys maps a result column to the SQL that selects it (sqlite: __rowid -> rowid)
    if not key:
        raise Error("readonly", "this table has no primary key, so its rows cannot be edited")
    if not isinstance(row_key, dict) or set(row_key) != set(key):
        raise Error("invalid", "every change needs the row's full key")
    parts, params = [], []
    for name in key:
        col = raw_keys.get(name) or d.quote(name)
        value = decode(row_key[name])
        if value is None:
            parts.append(f"{col} IS NULL")
        else:
            parts.append(f"{col} = {d.mark}")
            params.append(value)
    return " WHERE " + " AND ".join(parts), params


def changes(d, schema, table, columns, key, changes, raw_keys=None):
    """Statements for one commit: deletes, then updates, then inserts.

    Each item is (sql, params, expect_one); expect_one statements must touch
    exactly one row or the commit is rolled back.
    """
    target = d.table(schema, table)
    raw_keys = raw_keys or {}
    out = []
    for item in changes.get("deletes") or ():
        cond, params = _key_where(d, key, item.get("key"), raw_keys)
        out.append((f"DELETE FROM {target}{cond}", params, True))
    for item in changes.get("updates") or ():
        values = item.get("values") or {}
        if not values:
            raise Error("invalid", "an update needs at least one value")
        sets = [f"{d.quote(_column(columns, c))} = {d.mark}" for c in values]
        cond, kparams = _key_where(d, key, item.get("key"), raw_keys)
        out.append((f"UPDATE {target} SET {', '.join(sets)}{cond}",
                    [decode(v) for v in values.values()] + kparams, True))
    for item in changes.get("inserts") or ():
        values = item.get("values") or {}
        if not values:
            out.append((f"INSERT INTO {target} {d.default_values}", [], False))
            continue
        cols = ", ".join(d.quote(_column(columns, c)) for c in values)
        marks = ", ".join([d.mark] * len(values))
        out.append((f"INSERT INTO {target} ({cols}) VALUES ({marks})", [decode(v) for v in values.values()], False))
    return out


def literal(value, d=None):
    """A value written into SQL text: previews and SQL exports, never execution."""
    name = d.name if d else ""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, float) and not math.isfinite(value):
        value = {"nan": "NaN", "inf": "Infinity", "-inf": "-Infinity"}[repr(value)]
    elif isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        raw = bytes(value).hex()
        return f"'\\x{raw}'::bytea" if name == "postgresql" else "X'" + raw.upper() + "'"
    if hasattr(value, "is_finite") and value.is_finite():   # Decimal
        return str(value)
    if isinstance(value, (dict, list)):
        value = json.dumps(value, ensure_ascii=False)
    elif isinstance(value, (datetime.date, datetime.time)):
        value = value.isoformat(sep=" ") if isinstance(value, datetime.datetime) else value.isoformat()
    text = str(value).replace("'", "''")
    if name == "mysql":
        text = text.replace("\\", "\\\\")
    return "'" + text + "'"


def render(d, sql, params):
    pieces = sql.split(d.mark)
    out = [pieces[0]]
    for i, piece in enumerate(pieces[1:]):
        out.append(literal(params[i], d) if i < len(params) else d.mark)
        out.append(piece)
    return "".join(out)
