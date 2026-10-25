import csv
import json
import os
import sqlite3
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import adapters, transfer
from omatable.protocol import Error


class TransferTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        path = os.path.join(self.dir, "t.db")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, price REAL, raw BLOB)")
        db.executemany("INSERT INTO items VALUES (?, ?, ?, ?)",
                       [(1, "apple, red", 1.5, None), (2, 'say "hi"\nnow', None, b"\x00\xff"), (3, "ünï 50%", 2.0, None)])
        db.execute("CREATE TABLE copy (id INTEGER, name TEXT, price REAL)")
        db.commit()
        db.close()
        self.a = adapters.create({"engine": "sqlite", "path": path})
        self.a.connect()

    def tearDown(self):
        self.a.close()
        self.tmp.cleanup()

    def out(self, name):
        return os.path.join(self.dir, name)

    def test_csv_export(self):
        r = transfer.export(self.a, {"schema": "main", "table": "items", "sort": [{"column": "id"}]}, "csv", self.out("i.csv"))
        self.assertEqual(r["rows"], 3)
        self.assertEqual(stat.S_IMODE(os.stat(r["path"]).st_mode), 0o600)
        with open(r["path"], newline="", encoding="utf-8") as f:
            rows = list(csv.reader(f))
        self.assertEqual(rows[0], ["id", "name", "price", "raw"])
        self.assertEqual(rows[1], ["1", "apple, red", "1.5", ""])
        self.assertEqual(rows[2], ["2", 'say "hi"\nnow', "", "\\x00ff"])
        self.assertEqual(rows[3][1], "ünï 50%")
        self.assertEqual([f for f in os.listdir(self.dir) if f.endswith(".part")], [])

    def test_filtered_json_and_query_export(self):
        r = transfer.export(self.a, {"schema": "main", "table": "items",
                                     "filters": [{"column": "price", "op": ">", "value": 1.6}]}, "json", self.out("i.json"))
        with open(r["path"]) as f:
            self.assertEqual(json.load(f), [{"id": 3, "name": "ünï 50%", "price": 2.0, "raw": None}])
        r = transfer.export(self.a, {"sql": "SELECT id FROM items WHERE id > 5"}, "json", self.out("e.json"))
        with open(r["path"]) as f:
            self.assertEqual(json.load(f), [])
        r = transfer.export(self.a, {"sql": "SELECT raw FROM items WHERE id = 2"}, "json", self.out("b.json"))
        with open(r["path"]) as f:
            self.assertEqual(json.load(f), [{"raw": {"$t": "bytes", "v": "AP8="}}])

    def test_sql_export_reimports(self):
        r = transfer.export(self.a, {"schema": "main", "table": "items"}, "sql", self.out("i.sql"), table_name="again")
        self.a.query("CREATE TABLE again (id INTEGER PRIMARY KEY, name TEXT, price REAL, raw BLOB)")
        with open(r["path"]) as f:
            self.a.db.executescript(f.read())
        self.assertEqual(self.a.query("SELECT * FROM again ORDER BY id")[1], self.a.query("SELECT * FROM items ORDER BY id")[1])

    def test_export_refusals(self):
        transfer.export(self.a, {"schema": "main", "table": "items"}, "csv", self.out("x.csv"))
        with self.assertRaises(Error) as e:
            transfer.export(self.a, {"schema": "main", "table": "items"}, "csv", self.out("x.csv"))
        self.assertEqual(e.exception.code, "exists")
        self.assertEqual(transfer.export(self.a, {"schema": "main", "table": "items"}, "csv", self.out("x.csv"),
                                         overwrite=True)["rows"], 3)
        for target, fmt, path in (({"sql": "SELECT 1; SELECT 2"}, "csv", "y.csv"),
                                  ({"sql": "DELETE FROM items WHERE 0"}, "csv", "y.csv"),
                                  ({"schema": "main", "table": "items"}, "xml", "y.xml"),
                                  ({"schema": "main", "table": "items"}, "csv", "nope/y.csv")):
            with self.assertRaises(Error):
                transfer.export(self.a, target, fmt, self.out(path))
        self.assertFalse(os.path.exists(self.out("y.csv")))
        self.assertEqual(self.a.count("main", "items")["count"], 3)

    def write(self, name, text):
        with open(self.out(name), "w", encoding="utf-8") as f:
            f.write(text)
        return self.out(name)

    def test_preview_and_import(self):
        path = self.write("in.csv", "nr;label;cost;skip\n10;ten;;x\n11;\"el;even\";1.25;y\n")
        p = transfer.preview_csv(path)
        self.assertEqual((p["delimiter"], p["header"], p["count"]), (";", ["nr", "label", "cost", "skip"], 2))
        self.assertEqual(p["rows"][1], ["11", "el;even", "1.25", "y"])
        r = transfer.import_csv(self.a, "main", "copy", path, ["id", "name", "price", None], delimiter=";")
        self.assertEqual(r, {"inserted": 2})
        self.assertEqual(self.a.query("SELECT * FROM copy ORDER BY id")[1], [[10, "ten", None], [11, "el;even", 1.25]])

    def test_bad_row_rolls_back(self):
        self.a.query("CREATE TABLE strict_t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        path = self.write("bad.csv", "id,name\n1,a\n2,\n3,c\n")
        with self.assertRaises(Error) as e:
            transfer.import_csv(self.a, "main", "strict_t", path, ["id", "name"])
        self.assertIn("nothing was imported", e.exception.message)
        self.assertIn("line", e.exception.message)
        path = self.write("short.csv", "id,name\n1,a\n2\n")
        with self.assertRaises(Error) as e:
            transfer.import_csv(self.a, "main", "strict_t", path, ["id", "name"])
        self.assertIn("line 3 has 1 fields", e.exception.message)
        self.assertEqual(self.a.count("main", "strict_t")["count"], 0)
        for mapping in ([None, None], ["id", "id"], ["id", "nope"]):
            with self.assertRaises(Error):
                transfer.import_csv(self.a, "main", "strict_t", path, mapping)


if __name__ == "__main__":
    unittest.main()
