"""Which query results can be edited: a plain SELECT of one table.

A result is editable when its statement reads one table (no joins, grouping,
DISTINCT, set operations or subqueries in FROM) and its columns are that
table's own columns, its primary key included; edits then go through the
same commit as a table tab.
"""

import re

NAME = r'(?:"(?:[^"]|"")+"|`(?:[^`]|``)+`|\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_$]*)'
SIMPLE = re.compile(r"^\s*SELECT\s+(?P<cols>.+?)\s+FROM\s+(?P<from>.+?)"
                    r"(?:\s+(?:WHERE|ORDER\s+BY|LIMIT|OFFSET|FETCH|FOR)\b.*)?\s*;?\s*$", re.I | re.S)
FROM = re.compile(rf"^(?P<a>{NAME})(?:\s*\.\s*(?P<b>{NAME}))?(?:\s+(?:AS\s+)?(?P<alias>{NAME}))?$", re.I | re.S)
REFUSE = re.compile(r"\b(JOIN|UNION|INTERSECT|EXCEPT|GROUP\s+BY|HAVING|DISTINCT|WINDOW|OVER)\b", re.I)
STRINGS = re.compile(r"'(?:[^']|'')*'")


def _unquote(name):
    if name and name[0] in '"`[':
        inner = name[1:-1]
        return inner.replace('""', '"') if name[0] == '"' else inner.replace("``", "`") if name[0] == "`" else inner
    return name


def table_of(sql):
    """(schema or None, table, quoted: bool) for a plain one-table SELECT, else None."""
    bare = STRINGS.sub("''", str(sql))
    if REFUSE.search(bare):
        return None
    m = SIMPLE.match(bare)
    if not m:
        return None
    f = FROM.match(m.group("from").strip())
    if not f or (f.group("alias") or "").upper() in ("WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR"):
        return None
    if f.group("b"):
        return _unquote(f.group("a")), _unquote(f.group("b")), f.group("b")[0] in '"`['
    return None, _unquote(f.group("a")), f.group("a")[0] in '"`['
