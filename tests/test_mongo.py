"""The MongoDB adapter against the OmaDBngin server zt-mg (user dev).

Runs only with OMATABLE_TEST_DB=1. Uses the database zt_omatable and drops it.
"""

import datetime
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import adapters, dump, omadb
from omatable.protocol import Error

LIVE = os.environ.get("OMATABLE_TEST_DB") == "1"
DB = "zt_omatable"


@unittest.skipUnless(LIVE, "set OMATABLE_TEST_DB=1 with zt-mg running")
class MongoTest(unittest.TestCase):
    def setUp(self):
        from bson import ObjectId
        self.ObjectId = ObjectId
        self.a = adapters.create({**omadb.server("zt-mg"), "database": DB})
        self.a.connect()
        self.a.client.drop_database(DB)
        self.db = self.a.client[DB]
        self.oid = ObjectId()
        self.db.people.insert_many([
            {"_id": self.oid, "name": "ann", "age": 31, "tags": ["a", "b"], "at": datetime.datetime(2024, 1, 2)},
            {"_id": 2, "name": "bob", "age": 25, "score": 1.0},
            {"_id": "three", "name": "cy", "address": {"city": "Riyadh"}},
        ])
        self.db.create_collection("logs")
        self.db.command({"create": "adults", "viewOn": "people", "pipeline": [{"$match": {"age": {"$gte": 18}}}]})

    def tearDown(self):
        self.a.client.drop_database(DB)
        self.a.close()

    def test_version_databases_tree(self):
        self.assertTrue(self.a.version().startswith("MongoDB 8"))
        self.assertIn(DB, self.a.databases())
        tree = self.a.tree()
        self.assertEqual(tree[0]["name"], DB)
        self.assertEqual(tree[0]["tables"], ["logs", "people"])
        self.assertEqual(tree[0]["views"], ["adults"])
        self.a.use("admin")
        self.assertEqual(self.a.database, "admin")

    def test_find(self):
        out = self.a.find("people", sort="{age: -1}")
        self.assertEqual(out["columns"], ["_id", "name", "age", "tags", "at", "score", "address"])
        self.assertEqual([r[1] for r in out["rows"]], ["ann", "bob", "cy"])
        self.assertEqual(out["rows"][0][0], f"ObjectId('{self.oid}')")
        self.assertEqual(out["rows"][0][4], "2024-01-02T00:00:00.000Z")
        self.assertEqual(out["rows"][2][6], '{"city": "Riyadh"}')
        self.assertIsNone(out["rows"][2][2])
        self.assertEqual(json.loads(out["ids"][1]), {"$numberInt": "2"})
        self.assertIn('"score": 1.0', out["docs"][1])
        f = self.a.find("people", filter="{age: {$gt: 26}}")
        self.assertEqual([r[1] for r in f["rows"]], ["ann"])
        p = self.a.find("people", filter="{name: /^b/}", projection="{name: 1, _id: 0}")
        self.assertEqual((p["columns"], p["rows"], p["ids"]), (["name"], [["bob"]], [None]))
        page = self.a.find("people", sort="{name: 1}", skip=1, limit=1)
        self.assertEqual(([r[1] for r in page["rows"]], page["skip"], page["limit"]), (["bob"], 1, 1))
        self.assertEqual(len(self.a.find("adults")["rows"]), 2)
        with self.assertRaises(Error) as cm:
            self.a.find("people", filter="{age: {$bogus: 1}}")
        self.assertEqual(cm.exception.code, "query")
        with self.assertRaises(Error) as cm:
            self.a.find("people", filter="[1]")
        self.assertEqual(cm.exception.code, "invalid")

    def test_aggregate_and_count(self):
        out = self.a.aggregate("people", "[{$group: {_id: null, total: {$sum: '$age'}}}]")
        self.assertEqual((out["columns"], out["rows"]), (["_id", "total"], [[None, 56]]))
        self.assertEqual(len(self.a.aggregate("people", "[]", limit=2)["rows"]), 2)
        with self.assertRaises(Error):
            self.a.aggregate("people", "{a: 1}")
        self.assertEqual(self.a.count("people")["count"], 3)
        self.assertEqual(self.a.count("people", "{age: {$exists: true}}")["count"], 2)

    def test_insert_update_delete(self):
        r = self.a.insert("logs", "{msg: 'hi', n: NumberLong(5)}")
        self.assertEqual(r["inserted"], 1)
        self.assertEqual(self.db.logs.find_one()["msg"], "hi")
        self.assertEqual(self.a.insert("logs", "[{a: 1}, {a: 2}]")["inserted"], 2)
        with self.assertRaises(Error):
            self.a.insert("logs", "42")
        bob = self.a.find("people", filter="{_id: 2}")
        doc = json.loads(bob["docs"][0])
        doc["age"] = 26
        doc["new"] = {"$date": "2024-05-01T00:00:00Z"}
        self.a.update("people", bob["ids"][0], json.dumps(doc))
        saved = self.db.people.find_one({"_id": 2})
        self.assertEqual((saved["age"], type(saved["score"]), type(saved["new"])), (26, float, datetime.datetime))
        ann_id = self.a.find("people", filter=f"{{_id: ObjectId('{self.oid}')}}")["ids"][0]
        self.a.update("people", ann_id, "{name: 'ann2'}")  # no _id in the text keeps it
        self.assertEqual(self.db.people.find_one({"_id": self.oid})["name"], "ann2")
        with self.assertRaises(Error) as cm:
            self.a.update("people", ann_id, "{_id: 99, name: 'x'}")
        self.assertEqual(cm.exception.code, "invalid")
        with self.assertRaises(Error) as cm:
            self.a.update("people", '{"$numberInt": "404"}', "{a: 1}")
        self.assertEqual(cm.exception.code, "notfound")
        ids = self.a.find("people", filter="{_id: {$in: [2, 'three']}}")["ids"]
        self.assertEqual(self.a.delete("people", ids)["deleted"], 2)
        self.assertEqual(self.db.people.count_documents({}), 1)

    def test_indexes_and_collections(self):
        self.a.create_index("people", "{name: 1, age: -1}", unique=True)
        names = {i["name"]: i for i in self.a.indexes("people")}
        self.assertIn("name_1_age_-1", names)
        self.assertTrue(names["name_1_age_-1"]["unique"])
        self.assertEqual(names["name_1_age_-1"]["keys"], '{"name": 1, "age": -1}')
        self.a.drop_index("people", "name_1_age_-1")
        self.assertNotIn("name_1_age_-1", {i["name"] for i in self.a.indexes("people")})
        with self.assertRaises(Error):
            self.a.drop_index("people", "_id_")
        self.a.create_collection("fresh")
        self.assertIn("fresh", self.a.tree()[0]["tables"])
        with self.assertRaises(Error) as cm:
            self.a.create_collection("fresh")
        self.assertEqual(cm.exception.code, "query")
        self.a.drop_collection("fresh")
        self.assertNotIn("fresh", self.a.tree()[0]["tables"])
        with self.assertRaises(Error):
            self.a.create_collection("bad$name")

    def test_command(self):
        out = self.a.command("{ping: 1}")
        self.assertEqual(json.loads(out["reply"])["ok"], 1.0)
        stats = json.loads(self.a.command("{count: 'people'}")["reply"])
        self.assertEqual(stats["n"], 3)
        with self.assertRaises(Error):
            self.a.command("{notACommand: 1}")

    def test_create_drop_database(self):
        target = DB + "_new"
        self.a.client.drop_database(target)
        self.a.create_database(target, "first")
        self.assertIn(target, self.a.databases())
        self.assertEqual(self.a.client[target].list_collection_names(), ["first"])
        self.assertEqual(self.a.database, DB)
        with self.assertRaises(Error) as cm:
            self.a.create_database(target, "second")
        self.assertEqual(cm.exception.code, "exists")
        with self.assertRaises(Error):
            self.a.create_database("bad.name", "x")
        with self.assertRaises(Error):
            self.a.drop_database("admin")
        self.a.use(target)
        self.a.drop_database(target)
        self.assertNotIn(target, self.a.databases())
        self.assertEqual(self.a.database, "admin")

    def test_backup_restore(self):
        import tempfile
        self.a.create_index("people", "{name: 1}", unique=True)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = os.path.join(tmp.name, "zt.tar.gz")
        r = dump.backup(self.a, dump.Job(), out)
        self.assertGreater(r["bytes"], 100)
        target = DB + "_restored"
        self.a.client.drop_database(target)
        dump.restore(self.a, dump.Job(), out, target)
        db = self.a.client[target]
        self.assertEqual(sorted(db.list_collection_names()), ["adults", "logs", "people", "system.views"])
        self.assertEqual(db.people.count_documents({}), 3)
        self.assertEqual(db.people.find_one({"_id": self.oid})["at"], datetime.datetime(2024, 1, 2))
        self.assertIn("name_1", db.people.index_information())
        self.assertTrue(db.people.index_information()["name_1"]["unique"])
        self.assertEqual(db.adults.count_documents({}), 2)
        with self.assertRaises(Error) as cm:
            dump.restore(self.a, dump.Job(), out, target)
        self.assertEqual(cm.exception.code, "exists")
        self.a.client.drop_database(target)


if __name__ == "__main__":
    unittest.main()
