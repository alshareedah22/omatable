"""MySQL and MariaDB through PyMySQL. Databases are the top level of the tree."""

from .. import sqlsplit
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
