import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import files
from omatable.__main__ import build
from omatable.protocol import Error
from omatable.store import Keyring, Store


class FilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = self.tmp.name
        os.mkdir(os.path.join(self.d, "Sub"))
        for name, data in (("b.sql", b"select 1;"), ("A.SQL", b"x"), ("c.txt", b"t"), (".hidden.sql", b""),
                           ("bin.sql", b"\0\1\2")):
            with open(os.path.join(self.d, name), "wb") as f:
                f.write(data)

    def test_listing(self):
        out = files.listing(self.d, [".sql"])
        self.assertEqual(out["dir"], self.d)
        self.assertEqual(out["parent"], os.path.dirname(self.d))
        self.assertEqual([(e["name"], e["dir"]) for e in out["entries"]],
                         [("Sub", True), ("A.SQL", False), ("b.sql", False), ("bin.sql", False)])
        self.assertEqual(len(files.listing(self.d)["entries"]), 5)
        self.assertEqual(files.listing(os.path.join(self.d, "b.sql"))["dir"], self.d)
        self.assertEqual(files.listing("/")["parent"], "")
        with self.assertRaises(Error):
            files.listing(os.path.join(self.d, "nope"))

    def test_read_write(self):
        self.assertEqual(files.read_text(os.path.join(self.d, "b.sql"))["text"], "select 1;")
        with self.assertRaises(Error):
            files.read_text(os.path.join(self.d, "bin.sql"))
        with self.assertRaises(Error) as e:
            files.read_text(os.path.join(self.d, "b.sql"), limit=3)
        self.assertEqual(e.exception.code, "toolarge")
        out = files.write_text(os.path.join(self.d, "new.sql"), "select 2;")
        self.assertEqual(stat.S_IMODE(os.stat(out["path"]).st_mode), 0o600)
        with self.assertRaises(Error) as e:
            files.write_text(out["path"], "again")
        self.assertEqual(e.exception.code, "exists")
        files.write_text(out["path"], "again", overwrite=True)
        self.assertEqual(open(out["path"]).read(), "again")


class RunFileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.environ["OMATABLE_DBCTL"] = os.path.join(self.tmp.name, "none")
        self.addCleanup(os.environ.pop, "OMATABLE_DBCTL", None)
        db = os.path.join(self.tmp.name, "t.db")
        open(db, "wb").close()
        self.store = Store(os.path.join(self.tmp.name, "cfg"), Keyring(False))
        self.server = build(self.store)
        self.addCleanup(self.server.sessions.close_all)
        self.m = self.server.methods
        self.conn = self.store.save({"name": "t", "engine": "sqlite", "path": db, "tag": "local"})
        self.script = os.path.join(self.tmp.name, "s.sql")

    def write(self, text):
        with open(self.script, "w") as f:
            f.write(text)

    def test_run_file(self):
        sid = self.m["session.open"](id=self.conn["id"])["session"]
        self.write("CREATE TABLE t (x int);\nINSERT INTO t VALUES (1);\nINSERT INTO t VALUES (2), (3);\nSELECT * FROM t;\n")
        out = self.m["query.run_file"](session=sid, path=self.script)
        self.assertEqual((out["total"], out["ran"], out["affected"], out["ddl"]), (4, 4, 3, True))
        self.assertNotIn("error", out)
        self.write("INSERT INTO t VALUES (4);\nINSERT INTO nope VALUES (1);\nINSERT INTO t VALUES (5);")
        out = self.m["query.run_file"](session=sid, path=self.script)
        self.assertEqual((out["ran"], out["error"]["statement"]), (1, 2))
        self.assertIn("nope", out["error"]["message"])
        self.write("-- nothing here\n")
        with self.assertRaises(Error):
            self.m["query.run_file"](session=sid, path=self.script)

    def test_production_asks(self):
        self.store.save({**self.conn, "tag": "production"})
        sid = self.m["session.open"](id=self.conn["id"])["session"]
        self.write("SELECT 1;\nCREATE TABLE p (x int);")
        with self.assertRaises(Error) as e:
            self.m["query.run_file"](session=sid, path=self.script)
        self.assertEqual(e.exception.code, "confirm")
        self.assertIn("CREATE TABLE p", e.exception.detail)
        self.assertEqual(self.m["query.run_file"](session=sid, path=self.script, confirmed=True)["ran"], 2)


if __name__ == "__main__":
    unittest.main()
