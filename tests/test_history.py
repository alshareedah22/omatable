import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatableplus.history import History, Saved
from omatableplus.protocol import Error


class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "cfg")
        self.h = History(self.dir, keep=10)

    def tearDown(self):
        self.tmp.cleanup()

    def test_add_list_newest_first(self):
        self.h.add({"conn": "a", "sql": "SELECT 1", "ok": True})
        self.h.add({"conn": "b", "sql": "select name from users", "ok": False})
        items = self.h.list()
        self.assertEqual([i["sql"] for i in items], ["select name from users", "SELECT 1"])
        self.assertIn("ts", items[0])
        self.assertEqual([i["sql"] for i in self.h.list(conn="a")], ["SELECT 1"])
        self.assertEqual([i["sql"] for i in self.h.list(search="USERS")], ["select name from users"])
        self.assertEqual(len(self.h.list(limit=1)), 1)

    def test_private_and_trimmed(self):
        for n in range(30):
            self.h.add({"conn": "a", "sql": f"SELECT {n}"})
        self.assertEqual(stat.S_IMODE(os.stat(self.h.path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.dir).st_mode), 0o700)
        items = self.h.list(limit=100)
        self.assertLessEqual(len(items), 12)
        self.assertEqual(items[0]["sql"], "SELECT 29")

    def test_clear(self):
        self.h.add({"conn": "a", "sql": "SELECT 1"})
        self.h.add({"conn": "b", "sql": "SELECT 2"})
        self.h.clear(conn="a")
        self.assertEqual([i["sql"] for i in self.h.list()], ["SELECT 2"])
        self.h.clear()
        self.assertEqual(self.h.list(), [])

    def test_ignores_broken_lines(self):
        os.makedirs(self.dir)
        with open(self.h.path, "w") as f:
            f.write('{"sql": "SELECT 1"}\nnot json\n[1]\n')
        self.assertEqual([i["sql"] for i in self.h.list()], ["SELECT 1"])


class SavedTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = Saved(os.path.join(self.tmp.name, "cfg"))

    def tearDown(self):
        self.tmp.cleanup()

    def test_save_rename_delete(self):
        a = self.s.save("Top users", "SELECT * FROM users LIMIT 10")
        self.s.save("active", "SELECT 1")
        self.assertEqual([q["name"] for q in self.s.list()], ["active", "Top users"])
        self.assertEqual(stat.S_IMODE(os.stat(self.s.path).st_mode), 0o600)
        # same name overwrites; id renames
        self.s.save("Top users", "SELECT 2")
        self.assertEqual(len(self.s.list()), 2)
        b = self.s.save("Best users", "SELECT 3", id=a["id"])
        self.assertEqual(b["id"], a["id"])
        self.assertEqual(sorted(q["name"] for q in self.s.list()), ["Best users", "active"])
        self.s.delete(a["id"])
        self.assertEqual([q["name"] for q in self.s.list()], ["active"])

    def test_errors(self):
        with self.assertRaises(Error):
            self.s.save("", "SELECT 1")
        with self.assertRaises(Error):
            self.s.save("x", "  ")
        with self.assertRaises(Error) as e:
            self.s.delete("nope")
        self.assertEqual(e.exception.code, "notfound")


if __name__ == "__main__":
    unittest.main()
