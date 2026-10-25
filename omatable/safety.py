"""Safe mode: which operations change data, so production connections can
ask before running them. The checks lean towards asking: anything not known
to be read-only counts as a write.
"""

from . import sqlsplit

SQL_READ = {"SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "VALUES", "TABLE", "WITH", "USE", "PRAGMA", "HELP"}
# Words that make a SELECT/WITH/EXPLAIN write. Not REPLACE (a string function) or LOCK (LOCK IN SHARE MODE).
SQL_WRITE_WORDS = {"INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "DROP", "ALTER", "CREATE", "INTO"}
MONGO_READ = {"find", "aggregate", "count", "distinct", "dbstats", "collstats", "datasize", "listcollections",
              "listindexes", "listdatabases", "ping", "buildinfo", "serverstatus", "hello", "ismaster", "explain",
              "connectionstatus", "hostinfo", "getlog", "currentop", "top", "getcmdlineopts", "getparameter",
              "features", "whatsmyuri", "usersinfo", "rolesinfo", "getmore", "validate", "dbhash",
              "replsetgetstatus", "replsetgetconfig", "listcommands", "lockinfo"}


def sql_writes(statements, engine):
    """The statements that may change data or schema."""
    out = []
    for sql in statements:
        words = sqlsplit.words(sql, engine)
        first = words[0] if words else ""
        # SELECT … FOR UPDATE / FOR NO KEY UPDATE only locks rows
        words = [w for i, w in enumerate(words) if not (w == "UPDATE" and "FOR" in words[max(0, i - 3):i])]
        if first not in SQL_READ:
            out.append(sql)
        elif first == "PRAGMA" and "=" in sql:
            out.append(sql)
        elif first in ("WITH", "EXPLAIN", "SELECT") and SQL_WRITE_WORDS.intersection(words[1:]):
            # WITH … DELETE, EXPLAIN ANALYZE UPDATE, SELECT … INTO new_table / OUTFILE
            if first == "EXPLAIN" and "ANALYZE" not in words and "ANALYSE" not in words:
                continue
            out.append(sql)
    return out


def mongo_writes(command):
    """Whether a database command (a dict, name first) may change anything."""
    if not isinstance(command, dict) or not command:
        return True
    name = str(next(iter(command))).lower()
    if name not in MONGO_READ:
        return True
    if name == "aggregate":
        stages = command.get("pipeline") or []
        return any(isinstance(s, dict) and ("$out" in s or "$merge" in s) for s in stages)
    if name == "explain":
        return False
    return False


def pipeline_writes(stages):
    return any(isinstance(s, dict) and ("$out" in s or "$merge" in s) for s in stages or ())
