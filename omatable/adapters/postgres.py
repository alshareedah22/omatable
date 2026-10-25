"""PostgreSQL through psycopg 3."""

from ..protocol import Error
from .base import SQLAdapter

HIDDEN_SCHEMAS = ("NOT IN ('pg_catalog', 'information_schema') AND {0} NOT LIKE 'pg\\_toast%%' "
                  "AND {0} NOT LIKE 'pg\\_temp\\_%%'")


class Postgres(SQLAdapter):
    engine = "postgresql"

    def connect(self, database=None):
        import psycopg
        self.psycopg = psycopg
        c = self.conn
        dbname = database or self.database or "postgres"
        with self.guard():
            db = psycopg.connect(host=c.get("host") or "127.0.0.1", port=int(c.get("port") or 5432),
                                 user=c.get("user") or None, password=c.get("password") or None,
                                 dbname=dbname, sslmode=c.get("tls") or "prefer", connect_timeout=10,
                                 application_name="OmaTable", autocommit=True)
        self.close()
        self.db = db
        self.database = dbname
        self.forget()

    def translate(self, exc):
        psycopg = self.psycopg
        if not isinstance(exc, psycopg.Error):
            return None
        msg = str(exc).strip()
        state = getattr(exc, "sqlstate", None)
        low = msg.lower()
        if state == "57014":
            return Error("cancelled", "Query cancelled")
        if state in ("28P01", "28000") or "password authentication failed" in low or "no password supplied" in low:
            return Error("auth", msg)
        if state == "3D000" or ("database" in low and "does not exist" in low and isinstance(exc, psycopg.OperationalError)):
            return Error("notfound", msg)
        if isinstance(exc, psycopg.OperationalError) and state is None:
            return Error("network", msg)
        return Error("sql", msg)

    def describe(self, cursor):
        types = self.db.adapters.types
        return [getattr(types.get(d.type_code), "name", "") for d in cursor.description]

    def interrupt(self):
        self.db.cancel_safe(timeout=5)

    def version(self):
        return "PostgreSQL " + self.query("SHOW server_version")[1][0][0]

    def databases(self):
        return [r[0] for r in self.query("SELECT datname FROM pg_database WHERE NOT datistemplate "
                                         "AND datallowconn ORDER BY datname")[1]]

    def use(self, database):
        self.connect(database)

    def tree(self):
        self.forget()
        hide = HIDDEN_SCHEMAS.format("n.nspname")
        schemas = {r[0]: {"name": r[0], "tables": [], "views": [], "functions": [], "sequences": []}
                   for r in self.query(f"SELECT n.nspname FROM pg_namespace n WHERE n.nspname {hide} "
                                       "ORDER BY n.nspname = 'public' DESC, n.nspname")[1]}
        rels = self.query("SELECT n.nspname, c.relname, c.relkind FROM pg_class c "
                          "JOIN pg_namespace n ON n.oid = c.relnamespace "
                          f"WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S') AND n.nspname {hide} "
                          "AND NOT c.relispartition ORDER BY c.relname")[1]
        for schema, name, kind in rels:
            group = {"v": "views", "m": "views", "S": "sequences"}.get(kind, "tables")
            if schema in schemas:
                schemas[schema][group].append(name)
        funcs = self.query("SELECT DISTINCT n.nspname, p.proname FROM pg_proc p "
                           "JOIN pg_namespace n ON n.oid = p.pronamespace "
                           f"WHERE n.nspname {hide} AND p.prokind IN ('f', 'p') ORDER BY p.proname")[1]
        for schema, name in funcs:
            if schema in schemas:
                schemas[schema]["functions"].append(name)
        return list(schemas.values())

    def load_columns(self, schema, table):
        rows = self.query(
            "SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull, "
            "pg_get_expr(d.adbin, d.adrelid), COALESCE(a.attnum = ANY(i.indkey), false) "
            "FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid "
            "JOIN pg_namespace n ON n.oid = c.relnamespace "
            "LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
            "LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary "
            "WHERE n.nspname = %s AND c.relname = %s AND a.attnum > 0 AND NOT a.attisdropped "
            "ORDER BY a.attnum", (schema, table))[1]
        return [{"name": n, "type": t, "nullable": nullable, "default": dflt, "pk": pk}
                for n, t, nullable, dflt, pk in rows]

    def key(self, schema, table):
        rows = self.query(
            "SELECT array_agg(a.attname::text ORDER BY k.ord) FROM pg_index i "
            "JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace "
            "CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) "
            "JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum "
            "WHERE n.nspname = %s AND c.relname = %s AND c.relkind IN ('r', 'p') AND i.indisunique "
            "AND i.indpred IS NULL AND i.indexprs IS NULL "
            "GROUP BY i.indexrelid, i.indisprimary HAVING bool_and(a.attnotnull) "
            "ORDER BY i.indisprimary DESC, count(*) LIMIT 1", (schema, table))[1]
        return list(rows[0][0]) if rows else []
