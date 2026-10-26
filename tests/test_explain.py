"""Plan conversion for each engine, and query.explain on SQLite."""

import json
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatableplus import explain
from omatableplus.__main__ import build
from omatableplus.protocol import Error
from omatableplus.store import Keyring, Store

PG = [{"Plan": {"Node Type": "Hash Join", "Join Type": "Inner", "Total Cost": 30.5, "Plan Rows": 12,
                "Actual Total Time": 0.5, "Actual Rows": 10, "Actual Loops": 1, "Hash Cond": "(a.id = b.a_id)",
                "Plans": [{"Node Type": "Seq Scan", "Relation Name": "a", "Alias": "a", "Total Cost": 10,
                           "Plan Rows": 100, "Filter": "(x > 1)"},
                          {"Node Type": "Index Scan", "Relation Name": "bees", "Alias": "b", "Index Name": "b_pk",
                           "Total Cost": 8, "Plan Rows": 5, "Actual Total Time": 0.01, "Actual Loops": 4}]},
       "Planning Time": 0.2, "Execution Time": 0.7}]
MYSQL_TREE = """-> Nested loop inner join  (cost=2.10 rows=3) (actual time=0.05..0.08 rows=3 loops=1)
    -> Table scan on p  (cost=0.55 rows=3) (actual time=0.03..0.04 rows=3 loops=1)
    -> Single-row index lookup on t using PRIMARY (id=p.team_id)  (cost=0.30 rows=1) (actual time=0.01..0.01 rows=1 loops=3)
"""
MARIA = {"query_block": {"select_id": 1, "cost": 0.01, "nested_loop": [
    {"table": {"table_name": "p", "access_type": "ALL", "rows": 3, "filtered": 100, "attached_condition": "p.age > 1"}},
    {"table": {"table_name": "t", "access_type": "eq_ref", "key": "PRIMARY", "rows": 1, "filtered": 100}}]}}


class ConvertTest(unittest.TestCase):
    def test_postgres(self):
        out = explain.postgres(PG)
        root = out["nodes"][0]
        self.assertEqual((root["label"], root["cost"], root["rows"], root["actual_rows"]), ("Hash Join", 30.5, 12, 10))
        self.assertIn(["Hash Cond", "(a.id = b.a_id)"], root["detail"])
        self.assertEqual([c["label"] for c in root["children"]], ["Seq Scan on a", "Index Scan on bees b"])
        self.assertAlmostEqual(root["children"][1]["time_ms"], 0.04)   # per loop × loops
        self.assertEqual(out["summary"], {"planning_ms": 0.2, "execution_ms": 0.7})
        self.assertEqual(explain.postgres(json.dumps(PG))["nodes"][0]["label"], "Hash Join")

    def test_mysql_tree(self):
        out = explain.mysql_tree(MYSQL_TREE)
        root = out["nodes"][0]
        self.assertEqual((root["label"], root["cost"], root["rows"], root["actual_rows"], root["loops"]),
                         ("Nested loop inner join", 2.1, 3, 3, 1))
        self.assertEqual(len(root["children"]), 2)
        self.assertEqual(root["children"][1]["loops"], 3)
        self.assertTrue(root["children"][1]["label"].startswith("Single-row index lookup on t"))
        with self.assertRaises(Error):
            explain.mysql_tree("")

    def test_mariadb_json(self):
        root = explain.mysql_json(json.dumps(MARIA))["nodes"][0]
        self.assertEqual(root["label"], "query block #1")
        self.assertEqual([c["label"] for c in root["children"]], ["ALL on p", "eq_ref on t"])
        self.assertIn(["attached_condition", "p.age > 1"], root["children"][0]["detail"])

    def test_sqlite(self):
        out = explain.sqlite([(2, 0, 0, "SCAN p"), (5, 0, 0, "SEARCH t USING INTEGER PRIMARY KEY (rowid=?)"),
                              (7, 5, 0, "child")])
        self.assertEqual([n["label"] for n in out["nodes"]], ["SCAN p", "SEARCH t USING INTEGER PRIMARY KEY (rowid=?)"])
        self.assertEqual(out["nodes"][1]["children"][0]["label"], "child")


class QueryExplainTest(unittest.TestCase):
    def test_sqlite_session(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        os.environ["OMATABLEPLUS_DBCTL"] = os.path.join(tmp.name, "none")
        self.addCleanup(os.environ.pop, "OMATABLEPLUS_DBCTL", None)
        db = os.path.join(tmp.name, "t.db")
        with sqlite3.connect(db) as c:
            c.execute("CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT)")
        store = Store(os.path.join(tmp.name, "cfg"), Keyring(False))
        server = build(store)
        self.addCleanup(server.sessions.close_all)
        m = server.methods
        conn = store.save({"name": "t", "engine": "sqlite", "path": db, "tag": "local"})
        sid = m["session.open"](id=conn["id"])["session"]
        text = "SELECT 1;\nSELECT * FROM p WHERE id = 3;"
        out = m["query.explain"](session=sid, text=text, cursor=len(text) - 3)
        self.assertIn("SEARCH p", out["nodes"][0]["label"])
        self.assertEqual(out["sql"], "SELECT * FROM p WHERE id = 3")
        for bad in ({"text": text}, {"text": "EXPLAIN SELECT 1"}, {"text": ""},
                    {"text": "SELECT 1", "analyze": True}, {"text": "DELETE FROM p", "analyze": True}):
            with self.assertRaises(Error):
                m["query.explain"](session=sid, **bad)


if __name__ == "__main__":
    unittest.main()
