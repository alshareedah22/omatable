"""Staged structure changes to DDL, per dialect.

Names are quoted by the dialect. Types and defaults are SQL the user typed;
they are checked to be a single fragment (no ;, comments or line breaks) and
every statement is previewed before it runs. The statements run without
parameters, so they hold no placeholders and a % stays a %.
"""

import re

from . import sqlgen
from .protocol import Error

BAD = re.compile(r";|--|/\*|[\r\n]")
FK_SQL = {"postgresql": "CONSTRAINT", "mysql": "FOREIGN KEY"}


def check_fragment(text, what):
    text = str(text if text is not None else "").strip()
    if not text:
        raise Error("invalid", f"{what} is empty")
    if len(text) > 500 or BAD.search(text):
        raise Error("invalid", f"{what} must be one SQL fragment, without ;, comments or line breaks")
    return text


def check_name(name, what):
    name = str(name or "").strip()
    if not name or len(name) > 64:
        raise Error("invalid", f"the {what} name needs 1 to 64 characters")
    return name


def _mysql_def(d, col):
    parts = [col["type"], "NULL" if col.get("nullable", True) else "NOT NULL"]
    if col.get("default") is not None:
        parts.append("DEFAULT " + col["default"])
    if col.get("extra"):
        parts.append(col["extra"])
    if col.get("comment"):
        parts.append("COMMENT " + sqlgen.literal(col["comment"], d))
    return " ".join(parts)


def _plain_def(col):
    parts = [col["type"]]
    if not col.get("nullable", True):
        parts.append("NOT NULL")
    if col.get("default") is not None:
        parts.append("DEFAULT " + col["default"])
    return " ".join(parts)


def statements(d, schema, table, current, changes):
    name = d.name
    t = d.table(schema, table)
    q = d.quote
    cols = {c["name"]: c for c in current.get("columns") or ()}
    indexes = {i["name"]: i for i in current.get("indexes") or ()}
    fks = {f["name"] for f in current.get("foreign_keys") or ()}
    col_changes = changes.get("columns") or []
    idx_changes = changes.get("indexes") or []
    known = set(cols)        # column names an index may use once the changes are in
    out = []

    def unsupported(what):
        raise Error("unsupported", f"SQLite cannot {what}; recreate the table to do that")

    for fk in changes.get("foreign_keys") or ():
        if fk.get("op") != "drop":
            raise Error("invalid", "foreign keys can only be dropped here")
        if fk.get("name") not in fks:
            raise Error("notfound", f"no foreign key {fk.get('name')!r}")
        if name == "sqlite":
            unsupported("drop a foreign key")
        out.append(f"ALTER TABLE {t} DROP {FK_SQL[name]} {q(fk['name'])}")

    for ix in idx_changes:
        if ix.get("op") != "drop":
            continue
        cur = indexes.get(ix.get("name"))
        if cur is None:
            raise Error("notfound", f"no index {ix.get('name')!r}")
        if cur.get("primary"):
            raise Error("unsupported", "the primary key cannot be dropped here")
        if name == "mysql":
            out.append(f"DROP INDEX {q(cur['name'])} ON {t}")
        else:
            out.append(f"DROP INDEX {d.table(schema, cur['name'])}")

    for c in col_changes:
        if c.get("op") != "drop":
            continue
        if c.get("name") not in cols:
            raise Error("notfound", f"no column {c.get('name')!r}")
        known.discard(c["name"])
        out.append(f"ALTER TABLE {t} DROP COLUMN {q(c['name'])}")

    for c in col_changes:
        if c.get("op") != "alter":
            continue
        cur = cols.get(c.get("name"))
        if cur is None:
            raise Error("notfound", f"no column {c.get('name')!r}")
        old = cur["name"]
        new = check_name(c["new_name"], "column") if c.get("new_name") else old
        if new != old:
            if new in known:
                raise Error("invalid", f"there is already a column {new!r}")
            known.discard(old)
            known.add(new)
        if "type" in c:
            c = {**c, "type": check_fragment(c["type"], "the type")}
        if c.get("default") is not None:
            c = {**c, "default": check_fragment(c["default"], "the default")}
        if name == "sqlite":
            if any(k in c for k in ("type", "nullable", "default", "comment")):
                unsupported("change a column's type, NULL rule, default or comment")
            if new != old:
                out.append(f"ALTER TABLE {t} RENAME COLUMN {q(old)} TO {q(new)}")
        elif name == "mysql":
            merged = {**cur, **{k: c[k] for k in ("type", "nullable", "default", "comment") if k in c}}
            out.append(f"ALTER TABLE {t} CHANGE COLUMN {q(old)} {q(new)} {_mysql_def(d, merged)}")
        else:
            col = f"ALTER TABLE {t} ALTER COLUMN {q(old)}"
            if "type" in c:
                out.append(f"{col} TYPE {c['type']} USING {q(old)}::{c['type']}")
            if "nullable" in c:
                out.append(f"{col} {'DROP' if c['nullable'] else 'SET'} NOT NULL")
            if "default" in c:
                out.append(f"{col} DROP DEFAULT" if c["default"] is None else f"{col} SET DEFAULT {c['default']}")
            if "comment" in c:
                out.append(f"COMMENT ON COLUMN {t}.{q(old)} IS {sqlgen.literal(c['comment'] or None, d)}")
            if new != old:
                out.append(f"ALTER TABLE {t} RENAME COLUMN {q(old)} TO {q(new)}")

    for c in col_changes:
        if c.get("op") == "add":
            col = {"name": check_name(c.get("name"), "column"), "type": check_fragment(c.get("type"), "the type"),
                   "nullable": c.get("nullable", True), "comment": c.get("comment") or "",
                   "default": check_fragment(c["default"], "the default") if c.get("default") is not None else None}
            if col["name"] in known:
                raise Error("invalid", f"there is already a column {col['name']!r}")
            known.add(col["name"])
            if name == "mysql":
                out.append(f"ALTER TABLE {t} ADD COLUMN {q(col['name'])} {_mysql_def(d, col)}")
                continue
            if name == "sqlite" and col["comment"]:
                unsupported("store column comments")
            out.append(f"ALTER TABLE {t} ADD COLUMN {q(col['name'])} {_plain_def(col)}")
            if col["comment"]:
                out.append(f"COMMENT ON COLUMN {t}.{q(col['name'])} IS {sqlgen.literal(col['comment'], d)}")
        elif c.get("op") not in ("drop", "alter"):
            raise Error("invalid", f"unknown column change {c.get('op')!r}")

    for ix in idx_changes:
        if ix.get("op") == "add":
            ix_name = check_name(ix.get("name"), "index")
            columns = ix.get("columns") or []
            if not columns:
                raise Error("invalid", "an index needs at least one column")
            for col in columns:
                if col not in known:
                    raise Error("invalid", f"unknown column {col!r}")
            on = ", ".join(q(col) for col in columns)
            unique = "UNIQUE " if ix.get("unique") else ""
            if name == "sqlite":
                # SQLite puts the schema on the index, not on the table
                out.append(f"CREATE {unique}INDEX {d.table(schema, ix_name)} ON {q(table)} ({on})")
            else:
                out.append(f"CREATE {unique}INDEX {q(ix_name)} ON {t} ({on})")
        elif ix.get("op") != "drop":
            raise Error("invalid", f"unknown index change {ix.get('op')!r}")
    return out


def create_table(d, schema, table, columns):
    """One CREATE TABLE statement; a primary key over the columns marked pk."""
    table = check_name(table, "table")
    if not columns:
        raise Error("invalid", "a table needs at least one column")
    q = d.quote
    seen, lines, pk = set(), [], []
    for c in columns:
        col = {"name": check_name(c.get("name"), "column"), "type": check_fragment(c.get("type"), "the type"),
               "nullable": bool(c.get("nullable", True)) and not c.get("pk"),
               "default": check_fragment(c["default"], "the default") if c.get("default") not in (None, "") else None}
        if col["name"] in seen:
            raise Error("invalid", f"there are two columns named {col['name']!r}")
        seen.add(col["name"])
        if c.get("pk"):
            pk.append(q(col["name"]))
        lines.append(f"  {q(col['name'])} {_mysql_def(d, col) if d.name == 'mysql' else _plain_def(col)}")
    if pk:
        lines.append(f"  PRIMARY KEY ({', '.join(pk)})")
    return f"CREATE TABLE {d.table(schema, table)} (\n" + ",\n".join(lines) + "\n)"


def database(d, op, name):
    """CREATE or DROP DATABASE for the engines that have more than one."""
    if d.name == "sqlite":
        raise Error("unsupported", "a SQLite database is one file; add a connection for a new file instead")
    return f"{op} DATABASE {d.quote(check_name(name, 'database'))}"
