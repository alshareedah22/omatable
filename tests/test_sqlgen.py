import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import sqlgen
from omatable.protocol import Error

PG = sqlgen.dialect("postgresql")
MY = sqlgen.dialect("mariadb")
LITE = sqlgen.dialect("sqlite")
COLS = ["id", "name", "age"]


class QuoteTest(unittest.TestCase):
    def test_quote_per_dialect(self):
        self.assertEqual(PG.quote('we"ird'), '"we""ird"')
        self.assertEqual(MY.quote("we`ird"), "`we``ird`")
        self.assertEqual(LITE.table("main", "t"), '"main"."t"')
        self.assertEqual(PG.table("", "t"), '"t"')

    def test_mariadb_uses_mysql(self):
        self.assertIs(sqlgen.dialect("mariadb"), sqlgen.dialect("mysql"))
        with self.assertRaises(Error):
            sqlgen.dialect("redis")


class WhereTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(sqlgen.where(PG, COLS, []), ("", []))

    def test_unknown_column_and_op(self):
        with self.assertRaises(Error) as e:
            sqlgen.where(PG, COLS, [{"column": "x; drop", "op": "=", "value": 1}])
        self.assertEqual(e.exception.code, "invalid")
        with self.assertRaises(Error):
            sqlgen.where(PG, COLS, [{"column": "id", "op": "union", "value": 1}])

    def test_ops(self):
        sql, params = sqlgen.where(PG, COLS, [
            {"column": "id", "op": ">=", "value": 3},
            {"column": "name", "op": "contains", "value": "50%_off"},
            {"column": "age", "op": "null"},
        ])
        self.assertEqual(sql, ' WHERE "id" >= %s AND CAST("name" AS TEXT) ILIKE %s ESCAPE \'\\\' AND "age" IS NULL')
        self.assertEqual(params, [3, "%50\\%\\_off%"])

    def test_or_and_in(self):
        sql, params = sqlgen.where(LITE, COLS, [
            {"column": "id", "op": "in", "value": "1, 2,3"},
            {"column": "name", "op": "starts", "value": "a"},
            {"column": "name", "op": "not_null"},
        ], match="or")
        self.assertEqual(sql, ' WHERE "id" IN (?, ?, ?) OR "name" LIKE ? ESCAPE \'\\\' OR "name" IS NOT NULL')
        self.assertEqual(params, ["1", "2", "3", "a%"])

    def test_mysql_like(self):
        sql, params = sqlgen.where(MY, COLS, [{"column": "name", "op": "not_contains", "value": "x"},
                                              {"column": "name", "op": "ends", "value": "y"}])
        self.assertEqual(sql, " WHERE `name` NOT LIKE %s ESCAPE '\\\\' AND `name` LIKE %s ESCAPE '\\\\'")
        self.assertEqual(params, ["%x%", "%y"])


class SelectTest(unittest.TestCase):
    def test_select(self):
        sql, params = sqlgen.select(PG, "public", "users", COLS,
                                    sort=[{"column": "age", "desc": True}, {"column": "id"}],
                                    filters=[{"column": "id", "op": "<>", "value": 1}], limit=50, offset=100)
        self.assertEqual(sql, 'SELECT * FROM "public"."users" WHERE "id" <> %s '
                              'ORDER BY "age" DESC, "id" ASC LIMIT %s OFFSET %s')
        self.assertEqual(params, [1, 50, 100])

    def test_select_extra_and_bad_sort(self):
        sql, _ = sqlgen.select(LITE, "main", "t", COLS, extra="rowid AS __rowid, ")
        self.assertEqual(sql, 'SELECT rowid AS __rowid, * FROM "main"."t" LIMIT ? OFFSET ?')
        with self.assertRaises(Error):
            sqlgen.select(PG, "public", "t", COLS, sort=[{"column": "nope"}])

    def test_limit_bounds(self):
        _, params = sqlgen.select(PG, "public", "t", COLS, limit=10**9, offset=-5)
        self.assertEqual(params, [sqlgen.MAX_LIMIT, 0])

    def test_count(self):
        sql, params = sqlgen.count(MY, "shop", "t", COLS, [{"column": "age", "op": "<", "value": 9}])
        self.assertEqual(sql, "SELECT COUNT(*) FROM `shop`.`t` WHERE `age` < %s")
        self.assertEqual(params, [9])


class ChangesTest(unittest.TestCase):
    def test_order_and_sql(self):
        stmts = sqlgen.changes(PG, "public", "users", COLS, ["id"], {
            "inserts": [{"values": {"name": "new", "age": None}}, {"values": {}}],
            "updates": [{"key": {"id": 2}, "values": {"name": "b"}}],
            "deletes": [{"key": {"id": 3}}],
        })
        self.assertEqual(stmts, [
            ('DELETE FROM "public"."users" WHERE "id" = %s', [3], True),
            ('UPDATE "public"."users" SET "name" = %s WHERE "id" = %s', ["b", 2], True),
            ('INSERT INTO "public"."users" ("name", "age") VALUES (%s, %s)', ["new", None], False),
            ('INSERT INTO "public"."users" DEFAULT VALUES', [], False),
        ])

    def test_null_key_and_bytes(self):
        stmts = sqlgen.changes(LITE, "main", "t", COLS, ["id", "name"], {
            "updates": [{"key": {"id": 1, "name": None}, "values": {"age": {"$t": "bytes", "v": "AAE="}}}]})
        self.assertEqual(stmts, [('UPDATE "main"."t" SET "age" = ? WHERE "id" = ? AND "name" IS NULL',
                                  [b"\x00\x01", 1], True)])

    def test_rowid_key(self):
        stmts = sqlgen.changes(LITE, "main", "t", COLS, ["__rowid"], {"deletes": [{"key": {"__rowid": 4}}]},
                               raw_keys={"__rowid": "rowid"})
        self.assertEqual(stmts, [('DELETE FROM "main"."t" WHERE rowid = ?', [4], True)])

    def test_mysql_default_insert(self):
        self.assertEqual(sqlgen.changes(MY, "db", "t", COLS, ["id"], {"inserts": [{"values": {}}]}),
                         [("INSERT INTO `db`.`t` () VALUES ()", [], False)])

    def test_rejects(self):
        with self.assertRaises(Error):
            sqlgen.changes(PG, "public", "t", COLS, [], {"deletes": [{"key": {"id": 1}}]})
        with self.assertRaises(Error):
            sqlgen.changes(PG, "public", "t", COLS, ["id"], {"deletes": [{"key": {}}]})
        with self.assertRaises(Error):
            sqlgen.changes(PG, "public", "t", COLS, ["id"], {"updates": [{"key": {"id": 1}, "values": {"bad": 1}}]})
        with self.assertRaises(Error):
            sqlgen.changes(PG, "public", "t", COLS, ["id"], {"updates": [{"key": {"id": 1}, "values": {}}]})


class RenderTest(unittest.TestCase):
    def test_render(self):
        self.assertEqual(sqlgen.render(PG, 'UPDATE t SET a = %s, b = %s WHERE c = %s AND d = %s',
                                       ["it's", None, 5, b"\x01"]),
                         "UPDATE t SET a = 'it''s', b = NULL WHERE c = 5 AND d = X'01'")
        self.assertEqual(sqlgen.render(LITE, "x = ? AND y = ?", [True, 1.5]), "x = TRUE AND y = 1.5")


if __name__ == "__main__":
    unittest.main()
