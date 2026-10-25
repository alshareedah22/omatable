"""mongosh-style input -> BSON values, and grid cells. Needs pymongo (bson)."""

import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

try:
    import bson
except ImportError:  # system python without the venv
    bson = None

if bson is not None:
    from bson import Decimal128, Int64, ObjectId, Regex

    from omatable import mongojs
from omatable.protocol import Error

OID = "65a1b2c3d4e5f60718293a4b"


@unittest.skipIf(bson is None, "needs pymongo (run with the OmaTable venv)")
class ParseTest(unittest.TestCase):
    def test_empty_is_empty_filter(self):
        self.assertEqual(mongojs.parse(""), {})
        self.assertEqual(mongojs.parse("   "), {})

    def test_json_and_shell_syntax(self):
        self.assertEqual(mongojs.parse('{"age": {"$gt": 30}}'), {"age": {"$gt": 30}})
        self.assertEqual(mongojs.parse("{age: {$gt: 30}, name: 'ann'}"), {"age": {"$gt": 30}, "name": "ann"})
        self.assertEqual(mongojs.parse("{a: [1, 2,], b: {c: 'it\\'s'},}"), {"a": [1, 2], "b": {"c": "it's"}})
        self.assertEqual(mongojs.parse("{'quoted key': true, n: null, u: undefined}"),
                         {"quoted key": True, "n": None, "u": None})
        self.assertEqual(mongojs.parse("{x: -1.5e3, y: .5}"), {"x": -1500.0, "y": 0.5})
        self.assertEqual(mongojs.parse("{a: 1} // trailing comment"), {"a": 1})

    def test_constructors(self):
        got = mongojs.parse(f"{{_id: ObjectId('{OID}'), at: ISODate(\"2024-01-02T03:04:05Z\"),"
                            f" d: new Date('2024-01-02'), n: NumberLong(5), i: NumberInt('7'),"
                            f" m: NumberDecimal('1.10')}}")
        self.assertEqual(got["_id"], ObjectId(OID))
        self.assertEqual(got["at"].replace(tzinfo=None), datetime.datetime(2024, 1, 2, 3, 4, 5))
        self.assertEqual(got["d"].replace(tzinfo=None), datetime.datetime(2024, 1, 2))
        self.assertEqual((got["n"], type(got["n"])), (5, Int64))
        self.assertEqual(got["i"], 7)
        self.assertEqual(got["m"], Decimal128("1.10"))

    def test_regex_and_ejson(self):
        r = mongojs.parse("{name: /^an/i}")["name"]
        self.assertIsInstance(r, Regex)
        self.assertEqual((r.pattern, r.flags), ("^an", 2))
        self.assertEqual(mongojs.parse('{"_id": {"$oid": "%s"}}' % OID)["_id"], ObjectId(OID))

    def test_pipelines_and_errors(self):
        self.assertEqual(mongojs.parse("[{$match: {a: 1}}, {$limit: 5}]", "pipeline"),
                         [{"$match": {"a": 1}}, {"$limit": 5}])
        for bad in ("{a: }", "{a: 1", "{a: foo}", "{a: 'x}", "ObjectId('nothex')", "{a: Foo(1)}"):
            with self.assertRaises(Error) as cm:
                mongojs.parse(bad, "filter")
            self.assertEqual(cm.exception.code, "invalid")
            self.assertTrue(cm.exception.message.startswith("filter"), cm.exception.message)


@unittest.skipIf(bson is None, "needs pymongo (run with the OmaTable venv)")
class CellTest(unittest.TestCase):
    def test_cells(self):
        self.assertEqual(mongojs.cell("x"), "x")
        self.assertEqual(mongojs.cell(3), 3)
        self.assertEqual(mongojs.cell(2 ** 60), str(2 ** 60))
        self.assertEqual(mongojs.cell(float("nan")), "NaN")
        self.assertEqual(mongojs.cell(None), None)
        self.assertEqual(mongojs.cell(ObjectId(OID)), f"ObjectId('{OID}')")
        self.assertEqual(mongojs.cell(datetime.datetime(2024, 1, 2, 3, 4, 5)), "2024-01-02T03:04:05.000Z")
        self.assertEqual(mongojs.cell(Decimal128("1.10")), "1.10")
        self.assertEqual(mongojs.cell({"a": [1, ObjectId(OID)]}), '{"a": [1, {"$oid": "%s"}]}' % OID)
        self.assertEqual(mongojs.cell(b"\x00\x01")["$t"], "bytes")

    def test_dumps_round_trip(self):
        doc = {"_id": ObjectId(OID), "n": 1, "f": 1.0, "s": "é", "d": datetime.datetime(2024, 1, 2),
               "sub": {"x": [1, 2]}}
        text = mongojs.dumps(doc, indent=2)
        self.assertIn('"f": 1.0', text)
        back = mongojs.parse(text)
        self.assertEqual(back["_id"], doc["_id"])
        self.assertIsInstance(back["f"], float)
        self.assertIsInstance(back["n"], int)
        self.assertEqual(back["sub"], doc["sub"])
        self.assertEqual(mongojs.parse(mongojs.ident(ObjectId(OID))), ObjectId(OID))


if __name__ == "__main__":
    unittest.main()
