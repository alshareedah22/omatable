"""Server administration SQL: users (roles) and their privileges.

Every statement is built here from checked parts: names are quoted by the
dialect, privileges come from a fixed list, and passwords are written as
string literals. preview() shows the same statements with the password
masked, for the confirmation dialog and for production prompts.
"""

import re

from . import sqlgen
from .protocol import Error

MASK = "'••••••'"
PG_ROLE_FLAGS = ("login", "superuser", "createdb", "createrole", "replication")
PRIVILEGES = {
    "postgresql": {
        "database": ("CONNECT", "CREATE", "TEMPORARY", "ALL PRIVILEGES"),
        "schema": ("USAGE", "CREATE", "ALL PRIVILEGES"),
        "tables": ("SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "ALL PRIVILEGES"),
        "table": ("SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "ALL PRIVILEGES"),
    },
    "mysql": {
        "global": ("ALL PRIVILEGES", "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "INDEX",
                   "CREATE VIEW", "SHOW VIEW", "EXECUTE", "CREATE ROUTINE", "ALTER ROUTINE", "EVENT", "TRIGGER",
                   "LOCK TABLES", "CREATE TEMPORARY TABLES", "REFERENCES", "PROCESS", "RELOAD", "CREATE USER",
                   "GRANT OPTION"),
        "database": ("ALL PRIVILEGES", "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "INDEX",
                     "CREATE VIEW", "SHOW VIEW", "EXECUTE", "CREATE ROUTINE", "ALTER ROUTINE", "EVENT", "TRIGGER",
                     "LOCK TABLES", "CREATE TEMPORARY TABLES", "REFERENCES", "GRANT OPTION"),
        "table": ("ALL PRIVILEGES", "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "INDEX",
                  "CREATE VIEW", "SHOW VIEW", "TRIGGER", "REFERENCES", "GRANT OPTION"),
    },
}
HOST = re.compile(r"^[A-Za-z0-9_.%:\-]{1,255}$")


def _family(d):
    return "mysql" if d.name == "mysql" else d.name


def _name(value, what="user"):
    value = str(value or "").strip()
    if not value or len(value) > 63 or "\0" in value:
        raise Error("invalid", f"the {what} name needs 1 to 63 characters")
    return value


def _password(value):
    value = str(value or "")
    if "\0" in value or "\n" in value:
        raise Error("invalid", "the password cannot hold line breaks")
    return value


def account(d, spec):
    """The SQL name of a user: "role" for PostgreSQL, 'user'@'host' for MySQL."""
    name = _name(spec.get("name"))
    if d.name != "mysql":
        return d.quote(name)
    host = str(spec.get("host") or "%").strip()
    if not HOST.match(host):
        raise Error("invalid", "the host may hold letters, digits and . _ % : - only (% means any host)")
    return f"{sqlgen.literal(name, d)}@{sqlgen.literal(host, d)}"


def _pg_flags(spec):
    out = []
    for flag in PG_ROLE_FLAGS:
        if flag in spec:
            out.append(("" if spec[flag] else "NO") + flag.upper())
    return out


def create_user(d, spec):
    """[(sql, masked_sql)] creating a user, with its password and (PostgreSQL) attributes."""
    who = account(d, spec)
    pw = spec.get("password")
    if d.name == "mysql":
        sql = f"CREATE USER {who}"
        if pw:
            return [(sql + f" IDENTIFIED BY {sqlgen.literal(_password(pw), d)}", sql + f" IDENTIFIED BY {MASK}")]
        return [(sql, sql)]
    if d.name != "postgresql":
        raise Error("unsupported", "users are managed by PostgreSQL and MySQL/MariaDB only")
    flags = _pg_flags({"login": True, **spec})
    sql = f"CREATE ROLE {who} WITH " + " ".join(flags)
    if pw:
        return [(sql + f" PASSWORD {sqlgen.literal(_password(pw), d)}", sql + f" PASSWORD {MASK}")]
    return [(sql, sql)]


def alter_user(d, spec):
    """[(sql, masked)] changing a password and (PostgreSQL) attributes."""
    who = account(d, spec)
    out = []
    pw = spec.get("password")
    if d.name == "mysql":
        if pw:
            sql = f"ALTER USER {who} IDENTIFIED BY "
            out.append((sql + sqlgen.literal(_password(pw), d), sql + MASK))
        if "locked" in spec:
            sql = f"ALTER USER {who} ACCOUNT {'LOCK' if spec['locked'] else 'UNLOCK'}"
            out.append((sql, sql))
    else:
        flags = _pg_flags(spec)
        if flags:
            sql = f"ALTER ROLE {who} WITH " + " ".join(flags)
            out.append((sql, sql))
        if pw:
            sql = f"ALTER ROLE {who} WITH PASSWORD "
            out.append((sql + sqlgen.literal(_password(pw), d), sql + MASK))
        if spec.get("new_name") and spec["new_name"] != spec.get("name"):
            sql = f"ALTER ROLE {who} RENAME TO {d.quote(_name(spec['new_name']))}"
            out.append((sql, sql))
    if not out:
        raise Error("invalid", "There is nothing to change")
    return out


def drop_user(d, spec):
    sql = f"{'DROP USER' if d.name == 'mysql' else 'DROP ROLE'} {account(d, spec)}"
    return [(sql, sql)]


def _privileges(d, scope, privileges):
    allowed = PRIVILEGES.get(_family(d), {}).get(scope)
    if allowed is None:
        raise Error("invalid", f"unknown scope {scope!r}")
    privileges = [str(p).upper().strip() for p in privileges or ()]
    if not privileges:
        raise Error("invalid", "pick at least one privilege")
    for p in privileges:
        if p not in allowed:
            raise Error("invalid", f"{p} cannot be granted on a {scope}")
    if "ALL PRIVILEGES" in privileges:
        privileges = ["ALL PRIVILEGES"] + (["GRANT OPTION"] if "GRANT OPTION" in privileges else [])
    return privileges


def _target(d, spec):
    scope = spec.get("scope")
    q = d.quote
    if d.name == "mysql":
        if scope == "global":
            return "*.*"
        db = q(_name(spec.get("database"), "database"))
        if scope == "database":
            return f"{db}.*"
        if scope == "table":
            return f"{db}.{q(_name(spec.get('table'), 'table'))}"
    else:
        if scope == "database":
            return "DATABASE " + q(_name(spec.get("database"), "database"))
        if scope == "schema":
            return "SCHEMA " + q(_name(spec.get("schema"), "schema"))
        if scope == "tables":
            return "ALL TABLES IN SCHEMA " + q(_name(spec.get("schema"), "schema"))
        if scope == "table":
            return "TABLE " + d.table(_name(spec.get("schema"), "schema"), _name(spec.get("table"), "table"))
    raise Error("invalid", f"unknown scope {scope!r}")


def grant(d, spec, revoke=False):
    """[(sql, sql)] granting (or revoking) privileges on a scope."""
    if d.name not in ("postgresql", "mysql"):
        raise Error("unsupported", "users are managed by PostgreSQL and MySQL/MariaDB only")
    privileges = _privileges(d, spec.get("scope"), spec.get("privileges"))
    target = _target(d, spec)
    who = account(d, spec)
    option = "GRANT OPTION" in privileges and d.name == "mysql"
    names = ", ".join(p for p in privileges if p != "GRANT OPTION") or "USAGE"
    if revoke:
        sql = f"REVOKE {names} ON {target} FROM {who}"
        out = [(sql, sql)]
        if option:
            extra = f"REVOKE GRANT OPTION ON {target} FROM {who}"
            out.append((extra, extra))
        return out
    sql = f"GRANT {names} ON {target} TO {who}" + (" WITH GRANT OPTION" if option else "")
    out = [(sql, sql)]
    if d.name == "postgresql" and spec.get("scope") == "tables" and spec.get("future"):
        # tables created later in the schema get the same privileges
        extra = (f"ALTER DEFAULT PRIVILEGES IN SCHEMA {d.quote(_name(spec.get('schema'), 'schema'))} "
                 f"GRANT {names} ON TABLES TO {who}")
        out.append((extra, extra))
    return out
