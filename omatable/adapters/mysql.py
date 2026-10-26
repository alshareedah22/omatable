"""MySQL and MariaDB through PyMySQL. Databases are the top level of the tree."""

import re

from .. import sqlgen, sqlsplit
from ..protocol import Error
from .base import MAX_ROWS, SQLAdapter

SYSTEM = ("information_schema", "performance_schema", "mysql", "sys")
# PyMySQL FIELD_TYPE names that differ from the SQL type names people know.
SQL_TYPES = {"tiny": "tinyint", "short": "smallint", "long": "int", "int24": "mediumint",
             "longlong": "bigint", "newdecimal": "decimal", "var_string": "varchar", "string": "char",
             "newdate": "date", "tiny_blob": "blob", "medium_blob": "blob", "long_blob": "blob"}


class MySQL(SQLAdapter):
    engine = "mysql"

    def params(self):
        c = self.conn
        tls = c.get("tls") or "prefer"
        extra = {"ssl_disabled": True} if tls == "disable" else \
            {"ssl": {"check_hostname": False}} if tls == "require" else {}
        return {"host": c.get("host") or "127.0.0.1", "port": int(c.get("port") or 3306),
                "user": c.get("user") or None, "password": c.get("password") or "",
                "connect_timeout": 10, "charset": "utf8mb4", **extra}

    def connect(self):
        import pymysql
        from pymysql.constants import CLIENT
        self.pymysql = pymysql
        with self.guard():
            # FOUND_ROWS: rowcount is rows matched, not rows changed, so an
            # update that keeps a value still counts as touching its row.
            self.db = pymysql.connect(**self.params(), database=self.database or None,
                                      autocommit=True, client_flag=CLIENT.FOUND_ROWS)

    def interrupt(self):
        # The running connection is busy, so kill its query from a second one.
        side = self.pymysql.connect(**self.params())
        try:
            with side.cursor() as cur:
                cur.execute("KILL QUERY %s", (self.db.thread_id(),))
        finally:
            side.close()

    def stream_cursor(self):
        # unbuffered: rows come as they are read
        return self.db.cursor(self.pymysql.cursors.SSCursor)

    def describe(self, cursor):
        from pymysql.constants import FIELD_TYPE
        names = {v: SQL_TYPES.get(k.lower(), k.lower()) for k, v in vars(FIELD_TYPE).items() if k.isupper()}
        return [names.get(d[1], "") for d in cursor.description]

    def run(self, statements, max_rows=MAX_ROWS):
        out = super().run(statements, max_rows)
        if any(sqlsplit.keyword(s) == "USE" for s in statements):
            try:
                self.database = self.query("SELECT DATABASE()")[1][0][0] or ""
                self.forget()
            except Error:
                pass
            out["database"] = self.database
        return out

    def translate(self, exc):
        pymysql = self.pymysql
        if not isinstance(exc, pymysql.err.MySQLError):
            return None
        code = exc.args[0] if exc.args and isinstance(exc.args[0], int) else None
        msg = exc.args[1] if len(exc.args) > 1 else str(exc)
        if code == 1317:
            return Error("cancelled", "Query cancelled")
        if code in (1044, 1045, 1698):
            return Error("auth", msg)
        if code == 1049:
            return Error("notfound", msg)
        if code in (2002, 2003, 2005, 2006, 2013):
            return Error("network", msg)
        return Error("sql", msg)

    def version(self):
        v = self.query("SELECT VERSION()")[1][0][0]
        return ("MariaDB " if "mariadb" in v.lower() else "MySQL ") + v.split("-")[0]

    def databases(self):
        return [r[0] for r in self.query("SHOW DATABASES")[1]]

    def use(self, database):
        # "" means every database: queries are schema-qualified, so the
        # connection can keep whichever default it has.
        if database:
            with self.guard():
                self.db.select_db(database)
        self.database = database
        self.forget()

    def drop_database(self, name):
        out = super().drop_database(name)
        if name == self.database:
            self.database = ""
            self.forget()
        return out

    def tree(self):
        self.forget()
        if self.database:
            cond, params = "= %s", (self.database,)
            names = [self.database]
        else:
            cond, params = f"NOT IN ({', '.join(['%s'] * len(SYSTEM))})", SYSTEM
            names = [d for d in self.databases() if d not in SYSTEM]
        schemas = {n: {"name": n, "tables": [], "views": [], "functions": [], "sequences": []} for n in names}
        for schema, name, kind in self.query(
                "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES "
                f"WHERE TABLE_SCHEMA {cond} ORDER BY TABLE_NAME", params)[1]:
            if schema in schemas:
                schemas[schema]["views" if kind == "VIEW" else "tables"].append(name)
        for schema, name in self.query(
                "SELECT ROUTINE_SCHEMA, ROUTINE_NAME FROM information_schema.ROUTINES "
                f"WHERE ROUTINE_SCHEMA {cond} ORDER BY ROUTINE_NAME", params)[1]:
            if schema in schemas:
                schemas[schema]["functions"].append(name)
        return list(schemas.values())

    def catalog_rows(self):
        if self.database:
            cond, params = "= %s", (self.database,)
        else:
            cond, params = f"NOT IN ({', '.join(['%s'] * len(SYSTEM))})", SYSTEM
        return self.query(
            "SELECT c.TABLE_SCHEMA, c.TABLE_NAME, IF(t.TABLE_TYPE = 'VIEW', 'view', 'table'), c.COLUMN_NAME, "
            "c.COLUMN_TYPE FROM information_schema.COLUMNS c JOIN information_schema.TABLES t "
            "ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME "
            f"WHERE c.TABLE_SCHEMA {cond} ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION", params)[1]

    def load_columns(self, schema, table):
        rows = self.query("SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY "
                          "FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s "
                          "ORDER BY ORDINAL_POSITION", (schema, table))[1]
        return [{"name": n, "type": t, "nullable": nullable == "YES", "default": dflt, "pk": k == "PRI"}
                for n, t, nullable, dflt, k in rows]

    def key(self, schema, table):
        kind = self.query("SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = %s "
                          "AND TABLE_NAME = %s", (schema, table))[1]
        if not kind or kind[0][0] == "VIEW":
            return []
        nullable = {c["name"]: c["nullable"] for c in self.columns(schema, table)}
        indexes = {}
        for index, column in self.query(
                "SELECT INDEX_NAME, COLUMN_NAME FROM information_schema.STATISTICS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s AND NON_UNIQUE = 0 AND COLUMN_NAME IS NOT NULL "
                "ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX", (schema, table))[1]:
            indexes.setdefault(index, []).append(column)
        for cols in indexes.values():
            if not any(nullable.get(c, True) for c in cols):
                return cols
        return []

    def structure(self, schema, table):
        mariadb = "mariadb" in self.query("SELECT VERSION()")[1][0][0].lower()
        rows = self.query("SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_COMMENT, "
                          "COLUMN_KEY, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = %s "
                          "AND TABLE_NAME = %s ORDER BY ORDINAL_POSITION", (schema, table))[1]
        if not rows:
            raise Error("notfound", f"table {table!r} not found")
        columns = []
        for name, typ, nullable, dflt, comment, key, extra in rows:
            extra = extra or ""
            # MariaDB reports defaults as SQL already; MySQL gives the bare value
            # unless it is an expression.
            if mariadb:
                default = None if dflt in (None, "NULL") else dflt
            elif dflt is None:
                default = None
            elif "DEFAULT_GENERATED" in extra.upper():
                default = dflt if dflt.upper().startswith("CURRENT_TIMESTAMP") else f"({dflt})"
            else:
                default = sqlgen.literal(dflt, self.d)
            kept = re.findall(r"auto_increment|on update \S+", extra, re.I)
            columns.append({"name": name, "type": typ, "nullable": nullable == "YES", "default": default,
                            "comment": comment or "", "pk": key == "PRI", "extra": " ".join(kept)})
        indexes = {}
        for name, non_unique, column in self.query(
                "SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME FROM information_schema.STATISTICS "
                "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s "
                "ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX", (schema, table))[1]:
            ix = indexes.setdefault(name, {"name": name, "unique": not non_unique, "primary": name == "PRIMARY",
                                           "columns": []})
            ix["columns"].append(column)
        fks = {}
        for name, column, rs, rt, rc, upd, dele in self.query(
                "SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, "
                "k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE "
                "FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r "
                "ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME "
                "AND r.TABLE_NAME = k.TABLE_NAME WHERE k.TABLE_SCHEMA = %s AND k.TABLE_NAME = %s "
                "AND k.REFERENCED_TABLE_NAME IS NOT NULL ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION",
                (schema, table))[1]:
            fk = fks.setdefault(name, {"name": name, "columns": [], "ref_schema": rs, "ref_table": rt,
                                       "ref_columns": [], "on_update": upd, "on_delete": dele})
            fk["columns"].append(column)
            fk["ref_columns"].append(rc)
        create = self.query(f"SHOW CREATE TABLE {self.d.table(schema, table)}")[1][0][1]
        return {"columns": columns, "indexes": list(indexes.values()), "foreign_keys": list(fks.values()),
                "ddl": create + ";"}

    def run_ddl(self, statements):
        # MySQL commits every DDL statement itself; say how far it got.
        for i, sql in enumerate(statements):
            try:
                self.query(sql)
            except Error as e:
                done = f"; the {i} statement{'s' if i != 1 else ''} before it were applied" if i else \
                    "; nothing was changed"
                raise Error(e.code, e.message + done) from e
