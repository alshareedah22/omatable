"""The Redis/Valkey adapter against the OmaDB servers zt-vk and zt-rd.

Runs only with OMATABLE_TEST_DB=1. Uses database 9 and empties it.
"""

import base64
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import adapters, omadb
from omatable.protocol import Error

LIVE = os.environ.get("OMATABLE_TEST_DB") == "1"


def b(data):
    return {"$t": "bytes", "v": base64.b64encode(data).decode()}


class Flow:
    server = ""
    product = ""

    def setUp(self):
        self.a = adapters.create({**omadb.server(self.server), "database": "9"})
        self.a.connect()
        self.r = self.a.client
        self.r.flushdb()

    def tearDown(self):
        self.r.flushdb()
        self.a.close()

    def test_version_databases_use(self):
        self.assertTrue(self.a.version().startswith(self.product))
        dbs = self.a.databases()
        self.assertEqual(dbs[0], "0")
        self.assertIn("9", dbs)
        self.assertEqual(self.a.database, "9")
        self.r.set("here", "1")
        self.a.use("3")
        self.assertEqual(self.a.database, "3")
        self.assertEqual(self.a.client.exists("here"), 0)
        self.a.use("9")
        self.assertEqual(self.a.client.exists("here"), 1)
        with self.assertRaises(Error):
            self.a.use("nope")

    def test_scan(self):
        for i in range(30):
            self.r.set(f"user:{i}", i)
        self.r.hset("cfg", mapping={"a": "1"})
        self.r.set("temp", "x", ex=100)
        out = self.a.scan("user:*", "0", 500)
        self.assertEqual(len(out["keys"]), 30)
        self.assertEqual(out["cursor"], "0")
        self.assertEqual(out["total"], 32)
        self.assertEqual({k["type"] for k in out["keys"]}, {"string"})
        keys = sorted(k["key"] for k in out["keys"])
        self.assertEqual(keys[0], "user:0")
        hashes = self.a.scan("*", "0", 500, "hash")["keys"]
        self.assertEqual([k["key"] for k in hashes], ["cfg"])
        temp = self.a.scan("temp", "0", 500)["keys"][0]
        self.assertTrue(90 < temp["ttl"] <= 100)
        self.assertEqual(hashes[0]["ttl"], -1)
        # paging: small counts walk the cursor to the end without repeats
        seen, cursor = [], "0"
        while True:
            page = self.a.scan("*", cursor, 5)
            seen += [k["key"] for k in page["keys"]]
            cursor = page["cursor"]
            if cursor == "0":
                break
        self.assertEqual(len(set(seen)), 32)

    def test_get_each_type(self):
        self.r.set("s", "héllo")
        self.r.hset("h", mapping={"f1": "v1", "f2": "v2"})
        self.r.rpush("l", "a", "b", "a")
        self.r.sadd("st", "x", "y")
        self.r.zadd("z", {"m1": 1.5, "m2": -2})
        sid = self.r.xadd("x", {"k": "v"}).decode()
        self.assertEqual(self.a.get("s")["value"], "héllo")
        h = self.a.get("h")
        self.assertEqual((h["type"], h["size"], sorted(h["value"])), ("hash", 2, [["f1", "v1"], ["f2", "v2"]]))
        self.assertEqual(self.a.get("l")["value"], ["a", "b", "a"])
        self.assertEqual(self.a.get("st")["value"], ["x", "y"])
        self.assertEqual(self.a.get("z")["value"], [["m2", -2.0], ["m1", 1.5]])
        self.assertEqual(self.a.get("x")["value"], [{"id": sid, "fields": [["k", "v"]]}])
        g = self.a.get("s")
        self.assertEqual((g["ttl"], g["truncated"], g["editable"]), (-1, False, True))
        with self.assertRaises(Error) as cm:
            self.a.get("missing")
        self.assertEqual(cm.exception.code, "notfound")

    def test_binary_and_limits(self):
        self.r.set(b"\xff\x00key", b"\x80\x81")
        key = self.a.scan("*", "0", 10)["keys"][0]["key"]
        self.assertEqual(key, b(b"\xff\x00key"))
        self.assertEqual(self.a.get(key)["value"], b(b"\x80\x81"))
        self.a.edit(key, "string", "set", value=b(b"\x01\x02"))
        self.assertEqual(self.r.get(b"\xff\x00key"), b"\x01\x02")
        self.r.rpush("big", *range(1500))
        big = self.a.get("big")
        self.assertEqual((len(big["value"]), big["size"], big["truncated"]), (1000, 1500, True))
        self.r.set("huge", "x" * (1024 * 1024 + 10))
        huge = self.a.get("huge")
        self.assertEqual((len(huge["value"]), huge["truncated"], huge["editable"]), (1024 * 1024, True, False))

    def test_create(self):
        self.a.create("s", "string", "v", 50)
        self.assertEqual(self.r.get("s"), b"v")
        self.assertTrue(40 < self.r.ttl("s") <= 50)
        self.a.create("h", "hash", [["a", "1"], ["b", "2"]])
        self.assertEqual(self.r.hgetall("h"), {b"a": b"1", b"b": b"2"})
        self.a.create("l", "list", ["x", "y"])
        self.assertEqual(self.r.lrange("l", 0, -1), [b"x", b"y"])
        self.a.create("st", "set", ["x"])
        self.a.create("z", "zset", [["m", "2.5"]])
        self.assertEqual(self.r.zscore("z", "m"), 2.5)
        self.a.create("x", "stream", [["f", "v"]])
        self.assertEqual(self.r.xlen("x"), 1)
        with self.assertRaises(Error) as cm:
            self.a.create("s", "string", "again")
        self.assertEqual(cm.exception.code, "exists")
        with self.assertRaises(Error):
            self.a.create("empty", "hash", [])
        with self.assertRaises(Error):
            self.a.create("bad", "zset", [["m", "not a number"]])

    def test_edits(self):
        self.r.set("s", "v", ex=100)
        self.a.edit("s", "string", "set", value="w")
        self.assertEqual(self.r.get("s"), b"w")
        self.assertGreater(self.r.ttl("s"), 0)  # the TTL is kept
        self.r.hset("h", mapping={"a": "1", "b": "2"})
        self.a.edit("h", "hash", "set", item="a", value="9")
        self.a.edit("h", "hash", "set", item="c", value="3", old="b")  # rename b -> c
        self.a.edit("h", "hash", "delete", item="a")
        self.assertEqual(self.r.hgetall("h"), {b"c": b"3"})
        with self.assertRaises(Error):
            self.a.edit("h", "hash", "set", item="c", value="x", old="gone")
        self.r.rpush("l", "a", "b", "c")
        self.a.edit("l", "list", "set", item=1, value="B", old="b")
        self.a.edit("l", "list", "delete", item=0, old="a")
        self.a.edit("l", "list", "push", value="d")
        self.assertEqual(self.r.lrange("l", 0, -1), [b"B", b"c", b"d"])
        with self.assertRaises(Error) as cm:
            self.a.edit("l", "list", "set", item=0, value="z", old="stale")
        self.assertEqual(cm.exception.code, "conflict")
        self.r.sadd("st", "x", "y")
        self.a.edit("st", "set", "add", value="z")
        self.a.edit("st", "set", "set", value="Y", old="y")
        self.a.edit("st", "set", "delete", item="x")
        self.assertEqual(self.r.smembers("st"), {b"Y", b"z"})
        self.r.zadd("z", {"m": 1})
        self.a.edit("z", "zset", "set", item="m", score="5")
        self.a.edit("z", "zset", "set", item="n", score="6", old="m")
        self.a.edit("z", "zset", "set", item="o", score="1")
        self.a.edit("z", "zset", "delete", item="n")
        self.assertEqual(self.r.zrange("z", 0, -1, withscores=True), [(b"o", 1.0)])
        sid = self.r.xadd("x", {"a": "1"}).decode()
        self.a.edit("x", "stream", "add", value=[["b", "2"]])
        self.a.edit("x", "stream", "delete", item=sid)
        self.assertEqual(self.r.xlen("x"), 1)
        with self.assertRaises(Error):
            self.a.edit("s", "string", "explode")

    def test_delete_rename_expire(self):
        self.r.set("a", "1")
        self.r.set("b", "2")
        self.r.set("c", "3")
        self.assertEqual(self.a.delete(["a", "missing"])["deleted"], 1)
        self.a.rename("b", "b2")
        self.assertEqual(self.r.get("b2"), b"2")
        with self.assertRaises(Error) as cm:
            self.a.rename("b2", "c")
        self.assertEqual(cm.exception.code, "exists")
        self.a.expire("c", 30)
        self.assertTrue(20 < self.r.ttl("c") <= 30)
        self.a.expire("c", None)
        self.assertEqual(self.r.ttl("c"), -1)
        with self.assertRaises(Error):
            self.a.expire("missing", 10)

    def test_command(self):
        self.assertEqual(self.a.command("SET greeting 'hello world'")["reply"], "OK")
        self.assertEqual(self.a.command('GET greeting')["reply"], "hello world")
        self.assertEqual(self.a.command("RPUSH l a b")["reply"], 2)
        self.assertEqual(self.a.command("LRANGE l 0 -1")["reply"], ["a", "b"])
        self.assertIsNone(self.a.command("GET nothing")["reply"])
        self.a.command("ZADD z 120 m")
        self.assertIn(self.a.command("ZSCORE z m")["reply"], ({"$t": "double", "v": "120.0"}, "120"))
        with self.assertRaises(Error) as cm:
            self.a.command("HGET greeting x")
        self.assertIn("WRONGTYPE", cm.exception.message)
        for bad in ("SUBSCRIBE ch", "monitor", "", "SET 'unclosed"):
            with self.assertRaises(Error):
                self.a.command(bad)
        out = self.a.command("SELECT 4")
        self.assertEqual((out["reply"], out["database"], self.a.database), ("OK", "4", "4"))
        self.assertEqual(self.a.command("GET greeting")["reply"], None)


@unittest.skipUnless(LIVE, "set OMATABLE_TEST_DB=1 with zt-vk running")
class ValkeyTest(Flow, unittest.TestCase):
    server = "zt-vk"
    product = "Valkey 9"


@unittest.skipUnless(LIVE, "set OMATABLE_TEST_DB=1 with zt-rd running")
class RedisTest(Flow, unittest.TestCase):
    server = "zt-rd"
    product = "Redis 8"


if __name__ == "__main__":
    unittest.main()
