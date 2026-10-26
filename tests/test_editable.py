import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatableplus import editable
from omatableplus.__main__ import build
from omatableplus.store import Keyring, Store


class ParseTest(unittest.TestCase):
    def test_simple_selects(self):
        t = editable.table_of
        self.assertEqual(t("SELECT * FROM people"), (None, "people", False))
        self.assertEqual(t("select id, name from s.people p where id > 3 order by name limit 5;"), ("s", "people", False))
        self.assertEqual(t('SELECT * FROM "My Schema"."Odd ""T"""'), ("My Schema", 'Odd "T"', True))
        self.assertEqual(t("SELECT * FROM `db`.`t` AS x"), ("db", "t", True))
        self.assertEqual(t("SELECT * FROM t WHERE name = 'a JOIN b'"), (None, "t", False))

    def test_refused(self):
        for sql in ("SELECT * FROM a JOIN b ON a.id = b.a", "SELECT * FROM a, b", "SELECT DISTINCT x FROM a",
                    "SELECT x, count(*) FROM a GROUP BY x", "SELECT * FROM (SELECT 1) s", "SELECT 1",
                    "SELECT * FROM a UNION SELECT * FROM b", "WITH x AS (SELECT 1) SELECT * FROM x",
                    "UPDATE a SET x = 1", "SELECT row_number() OVER () FROM a"):
            self.assertIsNone(editable.table_of(sql), sql)


class SessionTest(unittest.TestCase):
    def test_sources_on_sqlite(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        os.environ["OMATABLEPLUS_DBCTL"] = os.path.join(tmp.name, "none")
        self.addCleanup(os.environ.pop, "OMATABLEPLUS_DBCTL", None)
        db = os.path.join(tmp.name, "t.db")
        with sqlite3.connect(db) as c:
            c.execute("CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT)")
            c.execute("CREATE TABLE nokey (a, b)")
            c.execute("INSERT INTO p VALUES (1, 'a'), (2, 'b')")
        store = Store(os.path.join(tmp.name, "cfg"), Keyring(False))
        server = build(store)
        self.addCleanup(server.sessions.close_all)
        m = server.methods
        conn = store.save({"name": "t", "engine": "sqlite", "path": db, "tag": "local"})
        sid = m["session.open"](id=conn["id"])["session"]
        run = lambda sql: m["query.run"](session=sid, text=sql)["results"][0].get("source")
        self.assertEqual(run("SELECT * FROM p WHERE id = 2"), {"schema": "main", "table": "p", "key": ["id"]})
        self.assertEqual(run("SELECT name, id FROM p")["table"], "p")
        self.assertIsNone(run("SELECT name FROM p"))            # no key
        self.assertIsNone(run("SELECT id, upper(name) FROM p"))  # computed column
        self.assertIsNone(run("SELECT * FROM nokey"))            # keyless table
        self.assertIsNone(run("SELECT * FROM nope"))
        changes = {"updates": [{"key": {"id": 2}, "values": {"name": "bee"}}]}
        m["table.commit"](session=sid, schema="main", table="p", changes=changes)
        self.assertEqual(m["query.run"](session=sid, text="SELECT name FROM p WHERE id = 2")["results"][0]["rows"], [["bee"]])


if __name__ == "__main__":
    unittest.main()
