"""User and privilege SQL (always), and users/processes against zt-pg and zt-my (OMATABLEPLUS_TEST_DB=1)."""

import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatableplus import adapters, admin, omadb, sqlgen
from omatableplus.protocol import Error

PG, MY, LITE = sqlgen.dialect("postgresql"), sqlgen.dialect("mysql"), sqlgen.dialect("sqlite")
LIVE = os.environ.get("OMATABLEPLUS_TEST_DB") == "1"


class SqlTest(unittest.TestCase):
    def test_create(self):
        self.assertEqual(admin.create_user(PG, {"name": "app", "password": "p'w", "createdb": True}),
                         [("CREATE ROLE \"app\" WITH LOGIN CREATEDB PASSWORD 'p''w'",
                           f"CREATE ROLE \"app\" WITH LOGIN CREATEDB PASSWORD {admin.MASK}")])
        self.assertEqual(admin.create_user(PG, {"name": "readers", "login": False})[0][0], 'CREATE ROLE "readers" WITH NOLOGIN')
        self.assertEqual(admin.create_user(MY, {"name": "app", "host": "localhost", "password": "a\\b"})[0],
                         ("CREATE USER 'app'@'localhost' IDENTIFIED BY 'a\\\\b'",
                          f"CREATE USER 'app'@'localhost' IDENTIFIED BY {admin.MASK}"))
        self.assertEqual(admin.create_user(MY, {"name": "x"})[0][0], "CREATE USER 'x'@'%'")
        for bad in ({"name": ""}, {"name": "a", "host": "bad host"}, {"name": "a", "password": "x\ny"}):
            with self.assertRaises(Error):
                admin.create_user(MY, bad)
        with self.assertRaises(Error):
            admin.create_user(LITE, {"name": "x"})

    def test_alter_drop(self):
        out = admin.alter_user(PG, {"name": "app", "password": "n", "superuser": False, "new_name": "app2"})
        self.assertEqual([m for _, m in out], ['ALTER ROLE "app" WITH NOSUPERUSER',
                                                f'ALTER ROLE "app" WITH PASSWORD {admin.MASK}',
                                                'ALTER ROLE "app" RENAME TO "app2"'])
        self.assertEqual(admin.alter_user(MY, {"name": "a", "host": "%", "locked": True})[0][0],
                         "ALTER USER 'a'@'%' ACCOUNT LOCK")
        with self.assertRaises(Error):
            admin.alter_user(PG, {"name": "app"})
        self.assertEqual(admin.drop_user(PG, {"name": "app"})[0][0], 'DROP ROLE "app"')
        self.assertEqual(admin.drop_user(MY, {"name": "a", "host": "h"})[0][0], "DROP USER 'a'@'h'")

    def test_grant_revoke(self):
        g = admin.grant(PG, {"name": "app", "scope": "tables", "schema": "public", "privileges": ["select", "INSERT"],
                             "future": True})
        self.assertEqual([s for s, _ in g], ['GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA "public" TO "app"',
                                             'ALTER DEFAULT PRIVILEGES IN SCHEMA "public" GRANT SELECT, INSERT ON TABLES TO "app"'])
        self.assertEqual(admin.grant(PG, {"name": "app", "scope": "database", "database": "shop", "privileges": ["CONNECT"]})[0][0],
                         'GRANT CONNECT ON DATABASE "shop" TO "app"')
        self.assertEqual(admin.grant(PG, {"name": "app", "scope": "table", "schema": "s", "table": "t",
                                          "privileges": ["DELETE"]}, revoke=True)[0][0],
                         'REVOKE DELETE ON TABLE "s"."t" FROM "app"')
        self.assertEqual(admin.grant(MY, {"name": "a", "host": "%", "scope": "database", "database": "shop",
                                          "privileges": ["SELECT", "GRANT OPTION"]})[0][0],
                         "GRANT SELECT ON `shop`.* TO 'a'@'%' WITH GRANT OPTION")
        self.assertEqual(admin.grant(MY, {"name": "a", "scope": "global", "privileges": ["ALL PRIVILEGES", "SELECT"]})[0][0],
                         "GRANT ALL PRIVILEGES ON *.* TO 'a'@'%'")
        rv = admin.grant(MY, {"name": "a", "scope": "table", "database": "d", "table": "t",
                              "privileges": ["UPDATE", "GRANT OPTION"]}, revoke=True)
        self.assertEqual([s for s, _ in rv], ["REVOKE UPDATE ON `d`.`t` FROM 'a'@'%'", "REVOKE GRANT OPTION ON `d`.`t` FROM 'a'@'%'"])
        for bad in ({"scope": "tables", "schema": "s", "privileges": []}, {"scope": "tables", "schema": "s", "privileges": ["DROP TABLE x"]},
                    {"scope": "galaxy", "privileges": ["SELECT"]}, {"scope": "database", "privileges": ["SELECT"]}):
            with self.assertRaises(Error):
                admin.grant(PG, {"name": "app", **bad})


def live(name, database):
    return {**omadb.server(name), "database": database}


@unittest.skipUnless(LIVE, "set OMATABLEPLUS_TEST_DB=1 with zt-pg and zt-my running")
class LiveTest(unittest.TestCase):
    def check_processes(self, conn, slow):
        a, b = adapters.create(conn), adapters.create(conn)
        a.connect()
        b.connect()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        done = {}
        t = threading.Thread(target=lambda: done.setdefault("r", a.run([slow])))
        t.start()
        time.sleep(1)
        mine = [p for p in b.processes() if slow.split("(")[0] in p["query"]]
        self.assertEqual(len(mine), 1, b.processes())
        b.kill(mine[0]["id"])
        t.join(10)
        self.assertIn("error", done["r"]["results"][-1])

    def roundtrip_user(self, a, spec, grant):
        for op, s in (("create", {**spec, "password": "S3cret'pw"}), ("grant", grant)):
            fn = admin.create_user if op == "create" else admin.grant
            a.admin_run([sql for sql, _ in fn(a.d, s)])
        names = [(u["name"], u["host"]) for u in a.users()]
        self.assertIn((spec["name"], spec.get("host", "%") if a.d.name == "mysql" else ""), names)
        grants = a.user_grants(spec)
        self.assertTrue(any("SELECT" in g for g in grants), grants)
        a.admin_run([sql for sql, _ in admin.grant(a.d, grant, revoke=True)])
        self.assertFalse(any("SELECT" in g and "people" in g.lower() for g in a.user_grants(spec)))
        a.admin_run([sql for sql, _ in admin.alter_user(a.d, {**spec, "password": "other"})])
        a.admin_run([sql for sql, _ in admin.drop_user(a.d, spec)])
        self.assertNotIn(spec["name"], [u["name"] for u in a.users()])

    def test_postgres(self):
        self.check_processes(live("zt-pg", "postgres"), "SELECT pg_sleep(30)")
        a = adapters.create(live("zt-pg", "postgres"))
        a.connect()
        self.addCleanup(a.close)
        a.query("DROP TABLE IF EXISTS zt_people")
        a.query("DROP ROLE IF EXISTS zt_user")
        a.query("CREATE TABLE zt_people (id int)")
        self.addCleanup(a.query, "DROP TABLE IF EXISTS zt_people")
        self.roundtrip_user(a, {"name": "zt_user"},
                            {"name": "zt_user", "scope": "table", "schema": "public", "table": "zt_people", "privileges": ["SELECT"]})
        users = {u["name"]: u for u in a.users()}
        self.assertTrue(users["dev"]["superuser"] or users["dev"]["login"])

    def test_mariadb(self):
        self.check_processes(live("zt-my", ""), "SELECT SLEEP(30)")
        a = adapters.create(live("zt-my", ""))
        a.connect()
        self.addCleanup(a.close)
        a.query("DROP DATABASE IF EXISTS zt_admin")
        a.query("CREATE DATABASE zt_admin")
        self.addCleanup(a.query, "DROP DATABASE IF EXISTS zt_admin")
        a.query("CREATE TABLE zt_admin.people (id int)")
        a.query("DROP USER IF EXISTS 'zt_user'@'localhost'")
        self.roundtrip_user(a, {"name": "zt_user", "host": "localhost"},
                            {"name": "zt_user", "host": "localhost", "scope": "table", "database": "zt_admin",
                             "table": "people", "privileges": ["SELECT"]})


if __name__ == "__main__":
    unittest.main()
