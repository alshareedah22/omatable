import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatable import ddl, sqlgen
from omatable.protocol import Error

PG, MY, LITE = sqlgen.dialect("postgresql"), sqlgen.dialect("mysql"), sqlgen.dialect("sqlite")
CURRENT = {
    "columns": [
        {"name": "id", "type": "int", "nullable": False, "default": None, "comment": "", "pk": True, "extra": "auto_increment"},
        {"name": "name", "type": "varchar(50)", "nullable": True, "default": "'x'", "comment": "", "pk": False, "extra": ""},
        {"name": "age", "type": "int", "nullable": True, "default": None, "comment": "years", "pk": False, "extra": ""},
    ],
    "indexes": [{"name": "PRIMARY", "columns": ["id"], "unique": True, "primary": True},
                {"name": "by_name", "columns": ["name"], "unique": False, "primary": False}],
    "foreign_keys": [{"name": "fk_team", "columns": ["age"], "ref_schema": "s", "ref_table": "teams",
                      "ref_columns": ["id"], "on_update": "NO ACTION", "on_delete": "CASCADE"}],
}


def gen(d, changes, schema="s"):
    return ddl.statements(d, schema, "people", CURRENT, changes)


class PostgresDDLTest(unittest.TestCase):
    def test_add_column(self):
        self.assertEqual(gen(PG, {"columns": [{"op": "add", "name": "email", "type": "text", "nullable": False,
                                               "default": "''", "comment": "who"}]}),
                         ['ALTER TABLE "s"."people" ADD COLUMN "email" text NOT NULL DEFAULT \'\'',
                          'COMMENT ON COLUMN "s"."people"."email" IS \'who\''])

    def test_alter_everything_renames_last(self):
        self.assertEqual(gen(PG, {"columns": [{"op": "alter", "name": "age", "new_name": "years", "type": "bigint",
                                               "nullable": False, "default": None, "comment": ""}]}),
                         ['ALTER TABLE "s"."people" ALTER COLUMN "age" TYPE bigint USING "age"::bigint',
                          'ALTER TABLE "s"."people" ALTER COLUMN "age" SET NOT NULL',
                          'ALTER TABLE "s"."people" ALTER COLUMN "age" DROP DEFAULT',
                          'COMMENT ON COLUMN "s"."people"."age" IS NULL',
                          'ALTER TABLE "s"."people" RENAME COLUMN "age" TO "years"'])

    def test_order_and_indexes(self):
        out = gen(PG, {"columns": [{"op": "add", "name": "x", "type": "int"}, {"op": "drop", "name": "name"}],
                       "indexes": [{"op": "add", "name": "by_x", "columns": ["x", "id"], "unique": True},
                                   {"op": "drop", "name": "by_name"}],
                       "foreign_keys": [{"op": "drop", "name": "fk_team"}]})
        self.assertEqual(out, ['ALTER TABLE "s"."people" DROP CONSTRAINT "fk_team"',
                               'DROP INDEX "s"."by_name"',
                               'ALTER TABLE "s"."people" DROP COLUMN "name"',
                               'ALTER TABLE "s"."people" ADD COLUMN "x" int',
                               'CREATE UNIQUE INDEX "by_x" ON "s"."people" ("x", "id")'])

    def test_index_on_renamed_or_dropped_column(self):
        out = gen(PG, {"columns": [{"op": "alter", "name": "age", "new_name": "years"}],
                       "indexes": [{"op": "add", "name": "i", "columns": ["years"]}]})
        self.assertEqual(out[-1], 'CREATE INDEX "i" ON "s"."people" ("years")')
        with self.assertRaises(Error):
            gen(PG, {"columns": [{"op": "drop", "name": "age"}], "indexes": [{"op": "add", "name": "i", "columns": ["age"]}]})

    def test_rejections(self):
        for bad in ({"columns": [{"op": "add", "name": "x", "type": "int; DROP TABLE t"}]},
                    {"columns": [{"op": "add", "name": "x", "type": "int", "default": "1 -- c"}]},
                    {"columns": [{"op": "add", "name": "x", "type": "int\nx"}]},
                    {"columns": [{"op": "add", "name": "", "type": "int"}]},
                    {"columns": [{"op": "add", "name": "age", "type": "int"}]},
                    {"columns": [{"op": "drop", "name": "nope"}]},
                    {"columns": [{"op": "alter", "name": "id", "new_name": "name"}]},
                    {"indexes": [{"op": "drop", "name": "PRIMARY"}]},
                    {"indexes": [{"op": "add", "name": "i", "columns": []}]},
                    {"foreign_keys": [{"op": "drop", "name": "nope"}]}):
            with self.assertRaises(Error, msg=bad):
                gen(PG, bad)

    def test_percent_stays_single(self):
        out = gen(PG, {"columns": [{"op": "add", "name": "p%", "type": "text", "default": "'50%'"}]})
        self.assertEqual(out, ['ALTER TABLE "s"."people" ADD COLUMN "p%" text DEFAULT \'50%\''])


class MySQLDDLTest(unittest.TestCase):
    def test_change_keeps_the_rest_of_the_definition(self):
        self.assertEqual(gen(MY, {"columns": [{"op": "alter", "name": "id", "type": "bigint"}]}),
                         ["ALTER TABLE `s`.`people` CHANGE COLUMN `id` `id` bigint NOT NULL auto_increment"])
        self.assertEqual(gen(MY, {"columns": [{"op": "alter", "name": "age", "new_name": "years", "default": "0"}]}),
                         ["ALTER TABLE `s`.`people` CHANGE COLUMN `age` `years` int NULL DEFAULT 0 COMMENT 'years'"])

    def test_add_drop_index_fk(self):
        self.assertEqual(gen(MY, {"columns": [{"op": "add", "name": "b", "type": "text", "comment": "it's \\ ok"}],
                                  "indexes": [{"op": "drop", "name": "by_name"}],
                                  "foreign_keys": [{"op": "drop", "name": "fk_team"}]}),
                         ["ALTER TABLE `s`.`people` DROP FOREIGN KEY `fk_team`",
                          "DROP INDEX `by_name` ON `s`.`people`",
                          "ALTER TABLE `s`.`people` ADD COLUMN `b` text NULL COMMENT 'it''s \\\\ ok'"])


class SQLiteDDLTest(unittest.TestCase):
    def test_supported(self):
        self.assertEqual(gen(LITE, {"columns": [{"op": "alter", "name": "age", "new_name": "years"},
                                                {"op": "add", "name": "b", "type": "TEXT", "default": "'z'"},
                                                {"op": "drop", "name": "name"}],
                                    "indexes": [{"op": "drop", "name": "by_name"},
                                                {"op": "add", "name": "i", "columns": ["b"]}]}, schema="main"),
                         ['DROP INDEX "main"."by_name"',
                          'ALTER TABLE "main"."people" DROP COLUMN "name"',
                          'ALTER TABLE "main"."people" RENAME COLUMN "age" TO "years"',
                          'ALTER TABLE "main"."people" ADD COLUMN "b" TEXT DEFAULT \'z\'',
                          'CREATE INDEX "main"."i" ON "people" ("b")'])

    def test_refused(self):
        for bad in ({"columns": [{"op": "alter", "name": "age", "type": "TEXT"}]},
                    {"columns": [{"op": "alter", "name": "age", "nullable": False}]},
                    {"columns": [{"op": "add", "name": "b", "type": "TEXT", "comment": "x"}]},
                    {"foreign_keys": [{"op": "drop", "name": "fk_team"}]}):
            with self.assertRaises(Error) as e:
                gen(LITE, bad, schema="main")
            self.assertEqual(e.exception.code, "unsupported")


if __name__ == "__main__":
    unittest.main()
