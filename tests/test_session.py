import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable.__main__ import build
from omatable.protocol import Error
from omatable.store import Keyring, Store
from tests.test_tunnel import SSHD, Sshd

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LIVE = os.environ.get("OMATABLE_TEST_DB") == "1"


class SessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["OMATABLE_DBCTL"] = os.path.join(self.tmp.name, "none")
        self.path = os.path.join(self.tmp.name, "app.db")
        db = sqlite3.connect(self.path)
        db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        db.executemany("INSERT INTO notes (body) VALUES (?)", [("one",), ("two",), ("three",)])
        db.commit()
        db.close()
        self.store = Store(os.path.join(self.tmp.name, "cfg"), Keyring(False))
        self.server = build(self.store)
        self.m = self.server.methods
        self.conn = self.store.save({"name": "Notes", "engine": "sqlite", "path": self.path, "tag": "production"})

    def tearDown(self):
        self.server.sessions.close_all()
        os.environ.pop("OMATABLE_DBCTL", None)
        self.tmp.cleanup()

    def test_open_browse_commit_close(self):
        info = self.m["session.open"](id=self.conn["id"])
        self.assertEqual(info["engine"], "sqlite")
        self.assertEqual(info["tag"], "production")
        self.assertEqual(info["databases"], ["main"])
        sid = info["session"]
        tree = self.m["schema.tree"](session=sid)
        self.assertEqual(tree["schemas"][0]["tables"], ["notes"])
        rows = self.m["table.rows"](session=sid, schema="main", table="notes", sort=[{"column": "id", "desc": True}])
        self.assertEqual(rows["rows"][0], [3, "three"])
        changes = {"updates": [{"key": {"id": 1}, "values": {"body": "uno"}}]}
        self.assertIn("'uno'", self.m["table.preview"](session=sid, schema="main", table="notes",
                                                       changes=changes)["statements"][0])
        self.assertEqual(self.m["table.commit"](session=sid, schema="main", table="notes", changes=changes),
                         {"affected": 1})
        self.assertEqual(self.m["table.count"](session=sid, schema="main", table="notes",
                                               filters=[{"column": "body", "op": "=", "value": "uno"}]), {"count": 1})
        self.m["session.close"](session=sid)
        with self.assertRaises(Error) as e:
            self.m["schema.tree"](session=sid)
        self.assertEqual(e.exception.code, "notfound")

    def test_conn_test_with_form_data(self):
        ok = self.m["conn.test"](conn={"name": "x", "engine": "sqlite", "path": self.path})
        self.assertTrue(ok["ok"])
        self.assertTrue(ok["version"].startswith("SQLite"))
        with self.assertRaises(Error) as e:
            self.m["conn.test"](conn={"name": "x", "engine": "sqlite", "path": self.path + "x"})
        self.assertEqual(e.exception.code, "notfound")
        with self.assertRaises(Error) as e:
            self.m["conn.test"](conn={"name": "", "engine": "sqlite"})
        self.assertEqual(e.exception.code, "invalid")

    def test_non_sql_engine(self):
        redis = self.store.save({"name": "R", "engine": "redis", "host": "127.0.0.1"})
        with self.assertRaises(Error) as e:
            self.m["session.open"](id=redis["id"])
        self.assertEqual(e.exception.code, "invalid")

    def test_sigterm_closes_cleanly(self):
        env = {**os.environ, "PYTHONPATH": ROOT, "OMATABLE_CONFIG": os.path.join(self.tmp.name, "cfg"),
               "OMATABLE_NO_KEYRING": "1"}
        proc = subprocess.Popen([sys.executable, "-m", "omatable"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                text=True, env=env)
        self.assertEqual(json.loads(proc.stdout.readline())["event"], "ready")
        proc.stdin.write(json.dumps({"id": 1, "method": "session.open", "params": {"id": self.conn["id"]}}) + "\n")
        proc.stdin.flush()
        self.assertIn("session", json.loads(proc.stdout.readline())["result"])
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=10), 0)
        proc.stdin.close()
        proc.stdout.close()


@unittest.skipUnless(LIVE and os.access(SSHD, os.X_OK), "set OMATABLE_TEST_DB=1 with zt-pg running")
class TunnelSessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["OMATABLE_SSH_KNOWN_HOSTS"] = os.path.join(self.tmp.name, "kh")
        self.sshd = Sshd()
        self.store = Store(os.path.join(self.tmp.name, "cfg"), Keyring(False))
        self.server = build(self.store)

    def tearDown(self):
        self.server.sessions.close_all()
        self.sshd.close()
        os.environ.pop("OMATABLE_SSH_KNOWN_HOSTS", None)
        self.tmp.cleanup()

    def test_postgres_over_ssh(self):
        from omatable import omadb
        pg = omadb.server("zt-pg")
        conn = self.store.save({"name": "via ssh", "engine": "postgresql", "host": "127.0.0.1", "port": pg["port"],
                                "user": pg["user"], "password": pg["password"], "database": "postgres",
                                "ssh": {"enabled": True, "host": "127.0.0.1", "port": self.sshd.port,
                                        "user": os.environ["USER"], "auth": "key", "key_path": self.sshd.key}})
        info = self.server.methods["session.open"](id=conn["id"])
        self.assertTrue(info["ssh"])
        self.assertTrue(info["version"].startswith("PostgreSQL"))
        session = self.server.sessions.get(info["session"])
        tunnel = session.tunnel
        self.assertTrue(tunnel.alive())
        self.server.methods["session.close"](session=info["session"])
        time.sleep(0.2)
        self.assertFalse(tunnel.alive())


if __name__ == "__main__":
    unittest.main()
