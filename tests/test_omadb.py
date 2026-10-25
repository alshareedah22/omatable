import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import omadb
from omatable.protocol import Error

STATE = {"services": [
    {"name": "app", "engine": "postgresql", "version": "17", "port": 5433, "mode": "native",
     "running": True, "user": "dev", "password": "pw"},
    {"name": "cache", "engine": "valkey", "version": "8", "port": 6380, "mode": "docker",
     "running": False, "user": "", "password": ""},
    {"name": "shop", "engine": "mysql", "version": "8.4", "port": 3307, "mode": "native",
     "running": True, "user": "root", "password": ""},
]}


class OmaDBTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ctl = os.path.join(self.tmp.name, "dbctl")
        with open(self.ctl, "w") as f:
            f.write("#!/bin/sh\n[ \"$1\" = state ] && cat <<'EOF'\n" + json.dumps(STATE) + "\nEOF\n")
        os.chmod(self.ctl, 0o755)
        os.environ["OMATABLE_DBCTL"] = self.ctl

    def tearDown(self):
        os.environ.pop("OMATABLE_DBCTL", None)
        self.tmp.cleanup()

    def test_finds_dbctl_under_the_new_or_old_plugin_name(self):
        os.environ.pop("OMATABLE_DBCTL")
        home = os.path.join(self.tmp.name, "home")
        old_home = os.environ.get("HOME")
        os.environ["HOME"] = home
        try:
            self.assertIsNone(omadb.dbctl_path())
            paths = {}
            for name in ("blackcode.omadb", "blackcode.omadbngin"):
                d = os.path.join(home, ".config/omarchy/plugins", name)
                os.makedirs(d)
                paths[name] = os.path.join(d, "dbctl")
                os.symlink(self.ctl, paths[name])
                self.assertEqual(omadb.dbctl_path(), paths["blackcode.omadbngin" if "blackcode.omadbngin" in paths else name])
        finally:
            os.environ["HOME"] = old_home

    def test_servers_public(self):
        servers = omadb.servers()
        self.assertEqual([s["id"] for s in servers], ["omadb:app", "omadb:cache", "omadb:shop"])
        app = servers[0]
        self.assertEqual(app["host"], "127.0.0.1")
        self.assertEqual(app["port"], 5433)
        self.assertEqual(app["database"], "postgres")
        self.assertEqual(app["tag"], "local")
        self.assertTrue(app["has_password"])
        self.assertNotIn("password", app)
        self.assertEqual(servers[1]["database"], "0")
        self.assertEqual(servers[2]["database"], "")

    def test_server_with_secret(self):
        self.assertEqual(omadb.server("app")["password"], "pw")
        with self.assertRaises(Error) as e:
            omadb.server("missing")
        self.assertEqual(e.exception.code, "notfound")

    def test_missing_dbctl_means_no_servers(self):
        os.environ["OMATABLE_DBCTL"] = os.path.join(self.tmp.name, "nope")
        self.assertEqual(omadb.servers(), [])

    def test_broken_output_means_no_servers(self):
        with open(self.ctl, "w") as f:
            f.write("#!/bin/sh\necho garbage\n")
        self.assertEqual(omadb.servers(), [])


    def test_import_omadb_copies_password(self):
        import tempfile as tf
        from omatable.__main__ import build
        from omatable.store import Store
        from tests.test_store import MemoryKeyring
        with tf.TemporaryDirectory() as cfg:
            store = Store(cfg, MemoryKeyring())
            server = build(store)
            saved = server.methods["conn.import_omadb"](
                name="app", conn={"name": "App", "engine": "postgresql", "host": "127.0.0.1", "port": 5433,
                                  "user": "dev", "database": "postgres", "omadb": "app"})
            self.assertEqual(store.get(saved["id"], secrets=True)["password"], "pw")


if __name__ == "__main__":
    unittest.main()
