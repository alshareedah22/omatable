import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatableplus.protocol import Error, Server


def run(lines, register):
    out = io.StringIO()
    server = Server(out)
    register(server)
    server.serve(io.StringIO("".join(json.dumps(l) + "\n" if not isinstance(l, str) else l for l in lines)))
    return [json.loads(x) for x in out.getvalue().splitlines()]


class ProtocolTest(unittest.TestCase):
    def test_result(self):
        def reg(s):
            s.method("math.add")(lambda a, b: a + b)
        replies = run([{"id": 1, "method": "math.add", "params": {"a": 2, "b": 3}}], reg)
        self.assertEqual(replies, [{"id": 1, "result": 5}])

    def test_typed_error(self):
        def reg(s):
            def boom():
                raise Error("invalid", "bad input")
            s.method("boom")(boom)
        replies = run([{"id": 2, "method": "boom"}], reg)
        self.assertEqual(replies, [{"id": 2, "error": {"code": "invalid", "message": "bad input"}}])

    def test_unexpected_exception_is_internal(self):
        def reg(s):
            s.method("crash")(lambda: 1 / 0)
        replies = run([{"id": 3, "method": "crash"}], reg)
        self.assertEqual(replies[0]["error"]["code"], "internal")
        self.assertIn("division", replies[0]["error"]["message"])

    def test_unknown_method(self):
        replies = run([{"id": 4, "method": "nope"}], lambda s: None)
        self.assertEqual(replies[0]["error"]["code"], "notfound")

    def test_bad_json_and_bad_params(self):
        def reg(s):
            s.method("one")(lambda a: a)
        replies = run(["not json\n", {"id": 5, "method": "one", "params": {"zzz": 1}}], reg)
        self.assertEqual(replies[0], {"id": None, "error": {"code": "protocol", "message": "invalid JSON"}})
        self.assertEqual(replies[1]["error"]["code"], "invalid")

    def test_blank_lines_ignored_and_concurrent_replies_all_arrive(self):
        def reg(s):
            s.method("echo")(lambda v: v)
        lines = ["\n"] + [{"id": i, "method": "echo", "params": {"v": i}} for i in range(50)]
        replies = run(lines, reg)
        self.assertEqual(sorted(r["result"] for r in replies), list(range(50)))

    def test_event(self):
        out = io.StringIO()
        Server(out).event("progress", text="hi", pct=10)
        self.assertEqual(json.loads(out.getvalue()), {"event": "progress", "text": "hi", "pct": 10})

    def test_bytes_and_dates_encode(self):
        import datetime
        import decimal
        out = io.StringIO()
        s = Server(out)
        s.send({"b": b"\x00\x01", "d": datetime.date(2026, 1, 2), "n": decimal.Decimal("1.50")})
        self.assertEqual(json.loads(out.getvalue()),
                         {"b": {"$t": "bytes", "v": "AAE="}, "d": "2026-01-02", "n": "1.50"})


import subprocess
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


class EndToEndTest(unittest.TestCase):
    def test_conn_methods_over_stdio(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {**os.environ, "PYTHONPATH": ROOT, "OMATABLEPLUS_CONFIG": tmp, "OMATABLEPLUS_NO_KEYRING": "1",
                   "OMATABLEPLUS_DBCTL": os.path.join(tmp, "none")}
            requests = [
                {"id": 1, "method": "conn.save", "params": {"conn": {
                    "name": "PG", "engine": "postgresql", "host": "localhost", "password": "pw"}}},
            ]
            out = subprocess.run([sys.executable, "-m", "omatableplus"], input="".join(json.dumps(r) + "\n" for r in requests),
                                 capture_output=True, text=True, env=env, timeout=30).stdout.splitlines()
            msgs = [json.loads(l) for l in out]
            self.assertEqual(msgs[0]["event"], "ready")
            saved = msgs[1]["result"]
            self.assertEqual(saved["password_storage"], "file")
            requests = [
                {"id": 2, "method": "conn.duplicate", "params": {"id": saved["id"]}},
            ]
            out = subprocess.run([sys.executable, "-m", "omatableplus"], input="".join(json.dumps(r) + "\n" for r in requests),
                                 capture_output=True, text=True, env=env, timeout=30).stdout.splitlines()
            copy = json.loads(out[1])["result"]
            requests = [
                {"id": 3, "method": "conn.delete", "params": {"id": copy["id"]}},
            ]
            subprocess.run([sys.executable, "-m", "omatableplus"], input="".join(json.dumps(r) + "\n" for r in requests),
                           capture_output=True, text=True, env=env, timeout=30)
            out = subprocess.run([sys.executable, "-m", "omatableplus"], input=json.dumps({"id": 4, "method": "conn.list"}) + "\n",
                                 capture_output=True, text=True, env=env, timeout=30).stdout.splitlines()
            listing = json.loads(out[1])["result"]
            self.assertEqual([c["name"] for c in listing["connections"]], ["PG"])
            self.assertEqual(listing["omadb"], [])
            self.assertFalse(listing["keyring"])
            self.assertNotIn("pw", out[1])


if __name__ == "__main__":
    unittest.main()
