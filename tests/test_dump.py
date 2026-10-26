"""Backup and restore. SQLite and the tool lookup always run; PostgreSQL and
MariaDB need the OmaDBngin servers zt-pg and zt-my (OMATABLE_TEST_DB=1).
"""

import os
import sqlite3
import stat
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import adapters, dump, omadb
from omatable.protocol import Error

LIVE = os.environ.get("OMATABLE_TEST_DB") == "1"


def live_conn(name, database):
    return {**omadb.server(name), "database": database}


class ToolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def fake(self, engine, version, name):
        d = os.path.join(self.tmp.name, "engines", engine, version, "bin")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(path, 0o755)
        return path

    def test_find_tool_prefers_the_server_major(self):
        p16 = self.fake("postgresql", "16.15.1", "pg_dump")
        p18 = self.fake("postgresql", "18.6.1", "pg_dump")
        with mock.patch.object(dump, "ENGINE_DIRS", (os.path.join(self.tmp.name, "engines"),)), \
                mock.patch("shutil.which", return_value=None):
            self.assertEqual(dump.find_tool(["pg_dump"], (16, 4)), p16)
            self.assertEqual(dump.find_tool(["pg_dump"], (17, 0)), p18)   # no 17: the newest
            self.assertEqual(dump.find_tool(["pg_dump"]), p18)
            with self.assertRaises(Error) as e:
                dump.find_tool(["mariadb-dump"])
            self.assertEqual(e.exception.code, "missing")

    def test_job_reports_the_last_error_line_and_cancels(self):
        job = dump.Job()
        with self.assertRaises(Error) as e:
            job.run(["sh", "-c", "echo noise >&2; echo 'real problem' >&2; exit 3"])
        self.assertEqual(e.exception.code, "tool")
        self.assertIn("real problem", e.exception.message)
        job = dump.Job()
        threading.Timer(0.3, job.cancel).start()
        start = time.monotonic()
        with self.assertRaises(Error) as e:
            job.run(["sleep", "20"])
        self.assertEqual(e.exception.code, "cancelled")
        self.assertLess(time.monotonic() - start, 5)

    def test_sqlite_backup(self):
        src = os.path.join(self.tmp.name, "a.db")
        with sqlite3.connect(src) as db:
            db.execute("CREATE TABLE t (x)")
            db.execute("INSERT INTO t VALUES (1), (2)")
        a = adapters.create({"engine": "sqlite", "path": src})
        a.connect()
        self.addCleanup(a.close)
        out = os.path.join(self.tmp.name, "b.db")
        r = dump.backup(a, dump.Job(), out)
        self.assertEqual(r["path"], out)
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)
        with sqlite3.connect(out) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM t").fetchone()[0], 2)
        with self.assertRaises(Error) as e:
            dump.backup(a, dump.Job(), out)
        self.assertEqual(e.exception.code, "exists")
        with self.assertRaises(Error):
            dump.restore(a, dump.Job(), out)
        self.assertEqual([f for f in os.listdir(self.tmp.name) if f.startswith(".omatable-")], [])


class LiveMixin:
    def round_trip(self, a, admin, create, drop):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = os.path.join(tmp.name, "zt.sql")
        r = dump.backup(a, dump.Job(), out)
        self.assertGreater(r["bytes"], 100)
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)
        with open(out) as f:
            self.assertIn("people", f.read())
        admin.query(drop)
        admin.query(create)
        r = dump.restore(a, dump.Job(), out, "zt_restored")
        self.assertEqual(r["database"], "zt_restored")
        return out


@unittest.skipUnless(LIVE, "set OMATABLE_TEST_DB=1 with zt-pg running")
class PostgresDumpTest(LiveMixin, unittest.TestCase):
    def test_round_trip(self):
        admin = adapters.create(live_conn("zt-pg", "postgres"))
        admin.connect()
        self.addCleanup(admin.close)
        for db in ("zt_dump", "zt_restored"):
            admin.query(f"DROP DATABASE IF EXISTS {db}")
        admin.query("CREATE DATABASE zt_dump")
        a = adapters.create(live_conn("zt-pg", "zt_dump"))
        a.connect()
        self.addCleanup(a.close)
        a.query("CREATE TABLE people (id serial PRIMARY KEY, name text)")
        a.query("INSERT INTO people (name) VALUES ('ann'), ('bob')")
        self.round_trip(a, admin, "CREATE DATABASE zt_restored", "DROP DATABASE IF EXISTS zt_restored")
        b = adapters.create(live_conn("zt-pg", "zt_restored"))
        b.connect()
        self.assertEqual(b.query("SELECT count(*) FROM people")[1][0][0], 2)
        b.close()
        # a failing restore changes nothing: the dump's tables already exist
        with self.assertRaises(Error) as e:
            dump.restore(a, dump.Job(), self._again(a), "zt_restored")
        self.assertEqual(e.exception.code, "tool")
        a.close()
        for db in ("zt_dump", "zt_restored"):
            admin.query(f"DROP DATABASE IF EXISTS {db}")

    def _again(self, a):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return dump.backup(a, dump.Job(), os.path.join(tmp.name, "again.sql"))["path"]


@unittest.skipUnless(LIVE, "set OMATABLE_TEST_DB=1 with zt-my running")
class MariaDBDumpTest(LiveMixin, unittest.TestCase):
    def test_round_trip(self):
        admin = adapters.create(live_conn("zt-my", ""))
        admin.connect()
        self.addCleanup(admin.close)
        for db in ("zt_dump", "zt_restored"):
            admin.query(f"DROP DATABASE IF EXISTS {db}")
        admin.query("CREATE DATABASE zt_dump")
        a = adapters.create(live_conn("zt-my", "zt_dump"))
        a.connect()
        self.addCleanup(a.close)
        a.query("CREATE TABLE people (id int AUTO_INCREMENT PRIMARY KEY, name varchar(20))")
        a.query("INSERT INTO people (name) VALUES ('ann'), ('bob')")
        self.round_trip(a, admin, "CREATE DATABASE zt_restored", "DROP DATABASE IF EXISTS zt_restored")
        self.assertEqual(admin.query("SELECT count(*) FROM zt_restored.people")[1][0][0], 2)
        for db in ("zt_dump", "zt_restored"):
            admin.query(f"DROP DATABASE IF EXISTS {db}")


if __name__ == "__main__":
    unittest.main()
