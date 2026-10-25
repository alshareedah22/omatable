"""Split editor text into statements without parsing SQL.

One pass over the text tracks quotes, comments, PostgreSQL dollar quotes and
the BEGIN … END body of CREATE TRIGGER/PROCEDURE/FUNCTION/EVENT, so only a
`;` outside all of them ends a statement. Offsets are kept so the editor can
show which statement ran.
"""

import re

ROUTINE = re.compile(r"\s*CREATE\b.*?\b(TRIGGER|PROCEDURE|FUNCTION|EVENT)\b", re.I | re.S)
DOLLAR = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# END followed by one of these closes a block other than BEGIN (MySQL).
END_OF = ("IF", "LOOP", "WHILE", "REPEAT")


def _ident(ch):
    return ch.isalnum() or ch in "_$"


def _mysql(engine):
    return engine in ("mysql", "mariadb")


def _comment(text, i, engine):
    """Length of the comment starting at i, or 0."""
    n = len(text)
    if text.startswith("--", i):
        # MySQL wants whitespace after "--"; otherwise 5--1 is arithmetic.
        if _mysql(engine) and i + 2 < n and not text[i + 2].isspace():
            return 0
        end = text.find("\n", i)
        return (n if end < 0 else end) - i
    if text[i] == "#" and (_mysql(engine) or engine is None):
        end = text.find("\n", i)
        return (n if end < 0 else end) - i
    if text.startswith("/*", i):
        depth, j = 1, i + 2
        nested = engine == "postgresql"
        while j < n and depth:
            if nested and text.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif text.startswith("*/", j):
                depth, j = depth - 1, j + 2
            else:
                j += 1
        return j - i
    return 0


def _quoted(text, i, engine):
    """Length of the quoted string or identifier starting at i, or 0."""
    n = len(text)
    ch = text[i]
    if ch == "$" and engine == "postgresql" and (i == 0 or not _ident(text[i - 1])):
        m = DOLLAR.match(text, i)
        if m:
            end = text.find(m.group(0), m.end())
            return (n if end < 0 else end + len(m.group(0))) - i
        return 0
    close = {"'": "'", '"': '"', "`": "`", "[": "]"}.get(ch)
    if close is None or (ch == "`" and not _mysql(engine)) or (ch == "[" and engine != "sqlite"):
        return 0
    backslash = ch in "'\"" and _mysql(engine) or (
        ch == "'" and engine == "postgresql" and i > 0 and text[i - 1] in "eE"
        and (i == 1 or not _ident(text[i - 2])))
    j = i + 1
    while j < n:
        c = text[j]
        if backslash and c == "\\":
            j += 2
            continue
        if c == close:
            if close != "]" and j + 1 < n and text[j + 1] == close:
                j += 2
                continue
            return j + 1 - i
        j += 1
    return n - i


def split(text, engine):
    out = []
    n = len(text)
    i = 0
    start = None          # first non-blank, non-comment character of the statement
    lead = None           # first non-blank character (comments included)
    depth = 0
    routine = None        # None: not checked yet for this statement
    while i <= n:
        if i == n or (text[i] == ";" and depth <= 0):
            if start is not None:
                end = min(i + 1, n)
                out.append((lead, end, text[lead:i].strip()))
            start = lead = None
            depth, routine = 0, None
            i += 1
            continue
        ch = text[i]
        if ch.isspace():
            i += 1
            continue
        if lead is None:
            lead = i
        skip = _comment(text, i, engine)
        if skip:
            i += skip
            continue
        if start is None:
            start = i
        skip = _quoted(text, i, engine)
        if skip:
            i += skip
            continue
        if (ch.isalpha() or ch == "_") and (i == 0 or not _ident(text[i - 1])):
            word = WORD.match(text, i).group(0)
            upper = word.upper()
            if upper in ("BEGIN", "CASE", "END"):
                if routine is None:
                    routine = bool(ROUTINE.match(text, start, i))
                if routine:
                    if upper in ("BEGIN", "CASE"):
                        depth += 1
                    else:
                        nxt = WORD.match(text, _skip_space(text, i + len(word)))
                        following = nxt.group(0).upper() if nxt else ""
                        if following not in END_OF:
                            depth -= 1
                        if following in END_OF or following == "CASE":
                            i = nxt.end()
                            continue
            i += len(word)
            continue
        i += 1
    return out


def _skip_space(text, i):
    while i < len(text) and text[i].isspace():
        i += 1
    return i


def at(text, pos, engine):
    """The statement the cursor is in (or just after)."""
    stmts = split(text, engine)
    if not stmts:
        return None
    pick = stmts[0]
    for s in stmts:
        if s[0] <= pos:
            pick = s
    return pick


def keyword(sql):
    i, n = 0, len(sql)
    while i < n:
        if sql[i].isspace() or sql[i] == "(":
            i += 1
            continue
        skip = _comment(sql, i, None)
        if skip:
            i += skip
            continue
        m = WORD.match(sql, i)
        return m.group(0).upper() if m else ""
    return ""


def from_utf16(text, pos):
    """A QML (UTF-16) offset as a Python string index."""
    units = 0
    for i, ch in enumerate(text):
        if units >= pos:
            return i
        units += 2 if ord(ch) > 0xFFFF else 1
    return len(text)


def to_utf16(text, pos):
    return len(text[:pos].encode("utf-16-le")) // 2
