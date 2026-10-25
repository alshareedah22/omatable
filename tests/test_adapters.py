"""Adapters against real databases.

SQLite always runs. PostgreSQL and MySQL need the OmaDB servers zt-pg and
zt-my and run only with OMATABLE_TEST_DB=1.
"""

import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import adapters, omadb, sqlsplit, transfer
from omatable.protocol import Error

LIVE = os.environ.get("OMATABLE_TEST_DB") == "1"

DDL = {
    "sqlite": ["CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, data BLOB)",
               "CREATE TABLE nokey (a INTEGER, b TEXT)",
               "CREATE VIEW v_people AS SELECT name FROM people"],
    "postgresql": ["CREATE TABLE people (id serial PRIMARY KEY, name text NOT NULL, age int, data bytea)",
                   "CREATE TABLE nokey (a int, b text)",
                   "CREATE TABLE ukey (code text NOT NULL UNIQUE, n int)",
                   "CREATE VIEW v_people AS SELECT name FROM people"],
    "mysql": ["CREATE TABLE people (id int AUTO_INCREMENT PRIMARY KEY, name varchar(50) NOT NULL, age int, data blob)",
              "CREATE TABLE nokey (a int, b text)",
              "CREATE TABLE ukey (code varchar(20) NOT NULL UNIQUE, n int)",
              "CREATE VIEW v_people AS SELECT name FROM people"],
}
SEED = [("ann", 31), ("bob", 25), ("cy_d", None), ("dee", 40), ("50%", 9)]


class Flow:
    """The same checks for every engine; subclasses provide self.a and self.schema."""

    engine = ""

    def seed(self):
        a = self.a
        for stmt in DDL["mysql" if self.engine == "mariadb" else self.engine]:
            a.query(stmt)
        mark = a.d.mark
        for name, age in SEED:
            a.query(f"INSERT INTO people (name, age) VALUES ({mark}, {mark})", (name, age))
        a.query(f"INSERT INTO nokey (a, b) VALUES (1, 'x'), (2, 'y')")

    def test_tree_and_columns(self):
        tree = {s["name"]: s for s in self.a.tree()}
        s = tree[self.schema]
        self.assertIn("people", s["tables"])
        self.assertIn("v_people", s["views"])
        cols = self.a.columns(self.schema, "people")
        self.assertEqual([c["name"] for c in cols], ["id", "name", "age", "data"])
        self.assertTrue(cols[0]["pk"])
        self.assertFalse(cols[1]["nullable"])
        self.assertEqual(self.a.key(self.schema, "people"), ["id"])

    def test_rows_sort_filter_page(self):
        r = self.a.rows(self.schema, "people", sort=[{"column": "age", "desc": True}], limit=2)
        self.assertEqual([c["name"] for c in r["columns"]], ["id", "name", "age", "data"])
        self.assertTrue(r["editable"])
        self.assertEqual(r["key"], ["id"])
        self.assertEqual(len(r["rows"]), 2)
        ages = [row[2] for row in self.a.rows(self.schema, "people", sort=[{"column": "age", "desc": True}],
                                               filters=[{"column": "age", "op": "not_null"}])["rows"]]
        self.assertEqual(ages, [40, 31, 25, 9])
        page = self.a.rows(self.schema, "people", sort=[{"column": "id"}], limit=2, offset=2)
        self.assertEqual([row[1] for row in page["rows"]], ["cy_d", "dee"])
        like = self.a.rows(self.schema, "people", filters=[{"column": "name", "op": "contains", "value": "%"}])
        self.assertEqual([row[1] for row in like["rows"]], ["50%"])
        under = self.a.rows(self.schema, "people", filters=[{"column": "name", "op": "contains", "value": "_"}])
        self.assertEqual([row[1] for row in under["rows"]], ["cy_d"])
        typed = self.a.rows(self.schema, "people", filters=[{"column": "age", "op": ">=", "value": "31"},
                                                            {"column": "id", "op": "in", "value": "1,4"}])
        self.assertEqual(sorted(row[1] for row in typed["rows"]), ["ann", "dee"])
        either = self.a.count(self.schema, "people", [{"column": "name", "op": "=", "value": "ann"},
                                                      {"column": "age", "op": "null"}], match="or")
        self.assertEqual(either["count"], 2)
        self.assertEqual(self.a.count(self.schema, "people")["count"], 5)

    def test_commit_and_preview(self):
        changes = {"updates": [{"key": {"id": 1}, "values": {"name": "anne", "age": "32"}}],
                   "deletes": [{"key": {"id": 2}}],
                   "inserts": [{"values": {"name": "eve", "data": {"$t": "bytes", "v": "AAE="}}}]}
        preview = self.a.preview(self.schema, "people", changes)["statements"]
        self.assertEqual(len(preview), 3)
        self.assertIn("DELETE FROM", preview[0])
        self.assertIn("'anne'", preview[1])
        self.assertEqual(self.a.commit(self.schema, "people", changes)["affected"], 3)
        rows = {r[1]: r for r in self.a.rows(self.schema, "people", sort=[{"column": "id"}])["rows"]}
        self.assertEqual(rows["anne"][2], 32)
        self.assertNotIn("bob", rows)
        self.assertEqual(rows["eve"][3], b"\x00\x01")
        # same value again still counts as touching the row
        self.assertEqual(self.a.commit(self.schema, "people",
                                       {"updates": [{"key": {"id": 1}, "values": {"name": "anne"}}]})["affected"], 1)

    def test_commit_rolls_back(self):
        bad = {"updates": [{"key": {"id": 1}, "values": {"name": "zed"}}],
               "deletes": [{"key": {"id": 999}}]}
        with self.assertRaises(Error) as e:
            self.a.commit(self.schema, "people", bad)
        self.assertEqual(e.exception.code, "sql")
        self.assertIn("nothing was saved", e.exception.message)
        names = [r[1] for r in self.a.rows(self.schema, "people")["rows"]]
        self.assertIn("ann", names)
        self.assertNotIn("zed", names)
        with self.assertRaises(Error) as e:
            self.a.commit(self.schema, "people", {"inserts": [{"values": {"age": 1}}]})  # name NOT NULL
        self.assertEqual(e.exception.code, "sql")
        self.assertEqual(self.a.count(self.schema, "people")["count"], 5)

    def test_views_and_keyless(self):
        v = self.a.rows(self.schema, "v_people")
        self.assertFalse(v["editable"])
        with self.assertRaises(Error) as e:
            self.a.commit(self.schema, "v_people", {"deletes": [{"key": {"name": "ann"}}]})
        self.assertEqual(e.exception.code, "readonly")
        self.assertFalse(self.a.rows(self.schema, "nokey")["editable"])


    def test_run_select_and_affected(self):
        r = self.a.run(["SELECT name, age FROM people ORDER BY id",
                        "UPDATE people SET age = 1 WHERE name = 'bob'"])["results"]
        self.assertEqual([c["name"] for c in r[0]["columns"]], ["name", "age"])
        self.assertEqual(r[0]["rows"][0], ["ann", 31])
        self.assertFalse(r[0]["truncated"])
        self.assertEqual(r[1]["affected"], 1)
        self.assertGreaterEqual(r[1]["ms"], 0)

    def test_run_passes_percent_signs_through(self):
        r = self.a.run(["SELECT 10 % 3, '50%' AS p"])["results"][0]
        self.assertEqual(r["rows"], [[1, "50%"]])

    def test_run_truncates(self):
        r = self.a.run(["SELECT * FROM people"], max_rows=2)["results"][0]
        self.assertEqual(len(r["rows"]), 2)
        self.assertTrue(r["truncated"])

    def test_run_stops_at_first_error(self):
        r = self.a.run(["SELECT 1", "SELECT * FROM nope", "SELECT 2"])["results"]
        self.assertEqual(len(r), 2)
        self.assertEqual(r[0]["rows"], [[1]])
        self.assertEqual(r[1]["error"]["code"], "sql")
        self.assertEqual(self.a.run(["SELECT 3"])["results"][0]["rows"], [[3]])

    def test_cancel(self):
        threading.Timer(0.5, self.a.cancel).start()
        start = time.monotonic()
        r = self.a.run([self.SLOW, "SELECT 2"])["results"]
        self.assertLess(time.monotonic() - start, 8)
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]["error"]["code"], "cancelled")
        self.assertEqual(self.a.run(["SELECT 3"])["results"][0]["rows"], [[3]])

    def test_cancel_when_idle_is_harmless(self):
        self.a.cancel()
        self.assertEqual(self.a.run(["SELECT 4"])["results"][0]["rows"], [[4]])


    def test_percent_in_table_name(self):
        self.a.query(f"CREATE TABLE {self.a.d.quote('pct%')} (id int PRIMARY KEY, v {self.TEXT})")
        self.a.commit(self.schema, "pct%", {"inserts": [{"values": {"id": 1, "v": "50%"}}]})
        r = self.a.rows(self.schema, "pct%", filters=[{"column": "v", "op": "contains", "value": "%"}])
        self.assertEqual(r["rows"], [[1, "50%"]])
        self.assertEqual(self.a.count(self.schema, "pct%")["count"], 1)

    def test_structure(self):
        s = self.a.structure(self.schema, "people")
        self.assertEqual([c["name"] for c in s["columns"]], ["id", "name", "age", "data"])
        self.assertTrue(s["columns"][0]["pk"])
        self.assertFalse(s["columns"][1]["nullable"])
        self.assertTrue(any(i["primary"] and i["columns"] == ["id"] for i in s["indexes"]))
        self.assertIn("CREATE TABLE", s["ddl"])
        self.assertIn("people", s["ddl"])

    def test_alter_round_trip(self):
        changes = {"columns": [{"op": "add", "name": "email", "type": self.TEXT, "default": "'none'"},
                               {"op": "alter", "name": "age", "new_name": "years"}],
                   "indexes": [{"op": "add", "name": "by_email", "columns": ["email"], "unique": False}]}
        preview = self.a.alter_preview(self.schema, "people", changes)["statements"]
        self.assertEqual(len(preview), 3)
        self.assertTrue(all(sql.endswith(";") for sql in preview))
        self.assertEqual(self.a.alter(self.schema, "people", changes), {"statements": 3})
        s = self.a.structure(self.schema, "people")
        names = [c["name"] for c in s["columns"]]
        self.assertEqual(names, ["id", "name", "years", "data", "email"])
        self.assertIn("none", next(c for c in s["columns"] if c["name"] == "email")["default"])
        self.assertIn("by_email", [i["name"] for i in s["indexes"]])
        self.assertIn("years", [c["name"] for c in self.a.rows(self.schema, "people")["columns"]])
        self.a.alter(self.schema, "people", {"indexes": [{"op": "drop", "name": "by_email"}],
                                             "columns": [{"op": "drop", "name": "email"}]})
        self.assertNotIn("email", [c["name"] for c in self.a.structure(self.schema, "people")["columns"]])
        with self.assertRaises(Error):
            self.a.alter(self.schema, "people", {})

    def test_foreign_keys_truncate_drop(self):
        self.a.query("CREATE TABLE orders (id int PRIMARY KEY, person_id int, "
                     "CONSTRAINT fk_person FOREIGN KEY (person_id) REFERENCES people(id))")
        fk = self.a.structure(self.schema, "orders")["foreign_keys"][0]
        self.assertEqual((fk["columns"], fk["ref_table"], fk["ref_columns"]), (["person_id"], "people", ["id"]))
        self.a.query("INSERT INTO orders (id, person_id) VALUES (1, 1)")
        self.a.truncate(self.schema, "orders")
        self.assertEqual(self.a.count(self.schema, "orders")["count"], 0)
        self.a.drop(self.schema, "orders")
        self.a.drop(self.schema, "v_people", "view")
        tree = {s["name"]: s for s in self.a.tree()}[self.schema]
        self.assertNotIn("orders", tree["tables"])
        self.assertNotIn("v_people", tree["views"])


    def test_export_import_round_trip(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        mark = self.a.d.mark
        self.a.query(f"UPDATE people SET data = {mark} WHERE name = {mark}", (b"\x00\xff", "ann"))
        target = {"schema": self.schema, "table": "people", "sort": [{"column": "id"}]}
        out = transfer.export(self.a, target, "csv", os.path.join(tmp.name, "p.csv"))
        self.assertEqual(out["rows"], 5)
        self.a.query(f"CREATE TABLE people2 (id int, name {self.TEXT}, age int)")
        self.assertEqual(transfer.preview_csv(out["path"])["header"], ["id", "name", "age", "data"])
        self.assertEqual(transfer.import_csv(self.a, self.schema, "people2", out["path"], ["id", "name", "age", None]),
                         {"inserted": 5})
        rows = self.a.query("SELECT id, name, age FROM people2 ORDER BY id")[1]
        self.assertEqual(rows[2], [3, "cy_d", None])
        self.assertEqual(rows[4][1], "50%")
        # an SQL export loads back into an identical table
        out = transfer.export(self.a, target, "sql", os.path.join(tmp.name, "p.sql"), table_name="people3")
        self.a.query(f"CREATE TABLE people3 (id int, name {self.TEXT}, age int, data {self.BLOB})")
        with open(out["path"]) as f:
            for _, _, sql in sqlsplit.split(f.read(), self.engine):
                self.a.query(sql)
        self.assertEqual(self.a.query("SELECT * FROM people3 ORDER BY id")[1],
                         self.a.query("SELECT * FROM people ORDER BY id")[1])
        out = transfer.export(self.a, {"sql": "SELECT name, age FROM people WHERE age > 30 ORDER BY age"}, "json",
                              os.path.join(tmp.name, "q.json"))
        with open(out["path"]) as f:
            self.assertEqual(json.load(f), [{"name": "ann", "age": 31}, {"name": "dee", "age": 40}])


class SQLiteTest(Flow, unittest.TestCase):
    TEXT = "TEXT"
    BLOB = "BLOB"
    SLOW = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
    engine = "sqlite"
    schema = "main"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "t.db")
        sqlite3.connect(self.path).close()
        self.a = adapters.create({"engine": "sqlite", "path": self.path})
        self.a.connect()
        self.seed()

    def tearDown(self):
        self.a.close()
        self.tmp.cleanup()

    def test_views_and_keyless(self):
        v = self.a.rows(self.schema, "v_people")
        self.assertFalse(v["editable"])
        r = self.a.rows(self.schema, "nokey", sort=[{"column": "a"}])
        self.assertTrue(r["editable"])
        self.assertEqual(r["key"], ["__rowid"])
        self.assertTrue(r["columns"][0]["hidden"])
        rowid = r["rows"][1][0]
        self.a.commit(self.schema, "nokey", {"updates": [{"key": {"__rowid": rowid}, "values": {"b": "z"}}]})
        self.assertEqual(self.a.rows(self.schema, "nokey", sort=[{"column": "a"}])["rows"][1][2], "z")

    def test_missing_and_bad_files(self):
        with self.assertRaises(Error) as e:
            adapters.create({"engine": "sqlite", "path": self.path + ".nope"}).connect()
        self.assertEqual(e.exception.code, "notfound")
        junk = os.path.join(self.tmp.name, "junk.db")
        with open(junk, "w") as f:
            f.write("not sqlite at all, definitely not" * 10)
        with self.assertRaises(Error):
            adapters.create({"engine": "sqlite", "path": junk}).connect()
        self.assertEqual(self.a.databases(), ["main"])
        self.assertTrue(self.a.version().startswith("SQLite"))


def live_conn(name, database):
    s = omadb.server(name)
    return {**s, "database": database}


@unittest.skipUnless(LIVE, "set OMATABLE_TEST_DB=1 with zt-pg running")
class PostgresTest(Flow, unittest.TestCase):
    TEXT = "text"
    BLOB = "bytea"
    SLOW = "SELECT pg_sleep(30)"
    engine = "postgresql"
    schema = "zt_flow"

    @classmethod
    def setUpClass(cls):
        admin = adapters.create(live_conn("zt-pg", "postgres"))
        admin.connect()
        admin.query("DROP DATABASE IF EXISTS zt_omatable")
        admin.query("CREATE DATABASE zt_omatable")
        admin.close()

    def setUp(self):
        self.a = adapters.create(live_conn("zt-pg", "zt_omatable"))
        self.a.connect()
        self.a.query("DROP SCHEMA IF EXISTS zt_flow CASCADE")
        self.a.query("CREATE SCHEMA zt_flow")
        self.a.query("SET search_path TO zt_flow")
        self.seed()

    def tearDown(self):
        self.a.close()

    def test_unique_key_and_databases(self):
        self.assertEqual(self.a.key(self.schema, "ukey"), ["code"])
        self.assertIn("zt_omatable", self.a.databases())
        self.assertTrue(self.a.version().startswith("PostgreSQL 17"))
        self.a.use("postgres")
        self.assertEqual(self.a.database, "postgres")
        self.assertNotIn("zt_flow", [s["name"] for s in self.a.tree()])

    def test_failed_alter_changes_nothing(self):
        with self.assertRaises(Error) as e:
            self.a.alter(self.schema, "people", {"columns": [{"op": "add", "name": "ok", "type": "int"},
                                                             {"op": "add", "name": "bad", "type": "nosuchtype"}]})
        self.assertIn("nothing was changed", e.exception.message)
        self.assertNotIn("ok", [c["name"] for c in self.a.structure(self.schema, "people")["columns"]])

    def test_structure_details(self):
        self.a.query("COMMENT ON COLUMN people.age IS 'years'")
        s = self.a.structure(self.schema, "people")
        age = next(c for c in s["columns"] if c["name"] == "age")
        self.assertEqual((age["type"], age["comment"]), ("integer", "years"))
        self.assertIn("nextval", s["columns"][0]["default"])
        self.assertIn("COMMENT ON COLUMN", s["ddl"])

    def test_result_types(self):
        cols = self.a.run(["SELECT id, name FROM people"])["results"][0]["columns"]
        self.assertEqual([c["type"] for c in cols], ["int4", "text"])

    def test_auth_and_network_errors(self):
        with self.assertRaises(Error) as e:
            adapters.create({**live_conn("zt-pg", "postgres"), "password": "wrong"}).connect()
        self.assertEqual(e.exception.code, "auth")
        with self.assertRaises(Error) as e:
            adapters.create({**live_conn("zt-pg", "postgres"), "port": 1}).connect()
        self.assertEqual(e.exception.code, "network")
        with self.assertRaises(Error) as e:
            adapters.create(live_conn("zt-pg", "zt_nope")).connect()
        self.assertEqual(e.exception.code, "notfound")


@unittest.skipUnless(LIVE, "set OMATABLE_TEST_DB=1 with zt-my running")
class MySQLTest(Flow, unittest.TestCase):
    TEXT = "varchar(40)"
    BLOB = "blob"
    SLOW = "SELECT SLEEP(30)"
    engine = "mariadb"
    schema = "zt_flow"

    def setUp(self):
        admin = adapters.create(live_conn("zt-my", ""))
        admin.connect()
        admin.query("DROP DATABASE IF EXISTS zt_flow")
        admin.query("CREATE DATABASE zt_flow")
        admin.close()
        self.a = adapters.create(live_conn("zt-my", "zt_flow"))
        self.a.connect()
        self.seed()

    def tearDown(self):
        self.a.query("DROP DATABASE IF EXISTS zt_flow")
        self.a.close()

    def test_unique_key_and_databases(self):
        self.assertEqual(self.a.key(self.schema, "ukey"), ["code"])
        self.assertIn("zt_flow", self.a.databases())
        self.assertTrue(self.a.version().startswith("MariaDB 11.8"))
        self.a.use("mysql")
        self.assertEqual([s["name"] for s in self.a.tree()], ["mysql"])
        self.a.use("")
        names = [s["name"] for s in self.a.tree()]
        self.assertIn("zt_flow", names)
        self.assertNotIn("mysql", names)

    def test_failed_alter_reports_progress(self):
        with self.assertRaises(Error) as e:
            self.a.alter(self.schema, "people", {"columns": [{"op": "add", "name": "ok", "type": "int"},
                                                             {"op": "add", "name": "bad", "type": "nosuchtype"}]})
        self.assertIn("the 1 statement before it were applied", e.exception.message)

    def test_change_keeps_auto_increment(self):
        self.a.alter(self.schema, "people", {"columns": [{"op": "alter", "name": "id", "type": "bigint"},
                                                         {"op": "alter", "name": "name", "comment": "who"}]})
        s = self.a.structure(self.schema, "people")
        self.assertEqual(s["columns"][0]["extra"], "auto_increment")
        self.assertEqual(s["columns"][0]["type"], "bigint(20)")
        self.assertEqual(s["columns"][1]["comment"], "who")
        self.assertFalse(s["columns"][1]["nullable"])

    def test_use_follows_the_editor(self):
        self.assertEqual(self.a.run(["USE mysql"])["database"], "mysql")
        self.assertEqual(self.a.database, "mysql")
        cols = self.a.run(["SELECT 1 AS n"])["results"][0]["columns"]
        self.assertIn(cols[0]["type"], ("int", "bigint"))

    def test_auth_and_network_errors(self):
        with self.assertRaises(Error) as e:
            adapters.create({**live_conn("zt-my", ""), "password": "wrong"}).connect()
        self.assertEqual(e.exception.code, "auth")
        with self.assertRaises(Error) as e:
            adapters.create({**live_conn("zt-my", ""), "port": 1}).connect()
        self.assertEqual(e.exception.code, "network")


if __name__ == "__main__":
    unittest.main()
