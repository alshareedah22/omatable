import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatableplus.sqlsplit import at, keyword, split


def sqls(text, engine="postgresql"):
    return [s for _, _, s in split(text, engine)]


class SplitTest(unittest.TestCase):
    def test_offsets(self):
        text = "SELECT 1;\n  SELECT 2 ;\nSELECT 3"
        self.assertEqual(split(text, "postgresql"),
                         [(0, 9, "SELECT 1"), (12, 22, "SELECT 2"), (23, 31, "SELECT 3")])

    def test_semicolons_inside_quotes_and_comments(self):
        text = "SELECT ';', \"a;b\" FROM t; -- x; y\nSELECT /* ; */ 2"
        self.assertEqual(sqls(text), ["SELECT ';', \"a;b\" FROM t", "SELECT /* ; */ 2"])

    def test_doubled_quote_and_mysql_backslash(self):
        self.assertEqual(sqls("SELECT 'it''s;'; SELECT 2"), ["SELECT 'it''s;'", "SELECT 2"])
        self.assertEqual(sqls(r"SELECT 'a\';b'; SELECT 2", "mysql"), [r"SELECT 'a\';b'", "SELECT 2"])
        # standard strings in PostgreSQL: a backslash is just a character
        self.assertEqual(sqls(r"SELECT 'a\'; SELECT 2"), [r"SELECT 'a\'", "SELECT 2"])
        self.assertEqual(sqls(r"SELECT E'a\';b'; SELECT 2"), [r"SELECT E'a\';b'", "SELECT 2"])

    def test_backticks_and_brackets(self):
        self.assertEqual(sqls("SELECT `a;b` FROM t; SELECT 2", "mysql"), ["SELECT `a;b` FROM t", "SELECT 2"])
        self.assertEqual(sqls("SELECT [a;b] FROM t; SELECT 2", "sqlite"), ["SELECT [a;b] FROM t", "SELECT 2"])

    def test_dollar_quotes(self):
        body = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END $$ LANGUAGE plpgsql"
        self.assertEqual(sqls(body + "; SELECT f()"), [body, "SELECT f()"])
        tagged = "DO $fn$ BEGIN PERFORM 1; $$ inner; END $fn$"
        self.assertEqual(sqls(tagged + ";SELECT 1"), [tagged, "SELECT 1"])
        self.assertEqual(sqls("SELECT $1; SELECT 2"), ["SELECT $1", "SELECT 2"])

    def test_nested_comments_in_postgres(self):
        self.assertEqual(sqls("SELECT /* a /* b; */ c; */ 1; SELECT 2"), ["SELECT /* a /* b; */ c; */ 1", "SELECT 2"])

    def test_mysql_comments(self):
        self.assertEqual(sqls("SELECT 1 # a; b\n; SELECT 2", "mysql"), ["SELECT 1 # a; b", "SELECT 2"])
        self.assertEqual(sqls("SELECT 5--1; SELECT 2", "mysql"), ["SELECT 5--1", "SELECT 2"])
        self.assertEqual(sqls("SELECT 1 -- a; b\n; SELECT 2", "mysql"), ["SELECT 1 -- a; b", "SELECT 2"])

    def test_trailing_comment_stays_out_of_the_next_statement(self):
        self.assertEqual(sqls("SELECT 1; -- first\n\nSELECT 2; /* two */"), ["SELECT 1", "SELECT 2"])
        self.assertEqual(sqls("SELECT 1; /* a\nb */ SELECT 2"), ["SELECT 1", "/* a\nb */ SELECT 2"])

    def test_comment_only_statements_dropped(self):
        self.assertEqual(sqls("SELECT 1; -- done\n/* end */"), ["SELECT 1"])
        self.assertEqual(split("  ;; ", "postgresql"), [])

    def test_trigger_body_kept_whole(self):
        trig = ("CREATE TRIGGER t AFTER INSERT ON a BEGIN UPDATE b SET n = n + 1; "
                "UPDATE c SET m = CASE WHEN 1 THEN 2 END; END")
        self.assertEqual(sqls(trig + "; SELECT 1", "sqlite"), [trig, "SELECT 1"])
        proc = ("CREATE PROCEDURE p() BEGIN IF 1 THEN SELECT 1; END IF; "
                "WHILE 0 DO SELECT 2; END WHILE; END")
        self.assertEqual(sqls(proc + "; SELECT 3", "mysql"), [proc, "SELECT 3"])
        self.assertEqual(sqls("BEGIN; SELECT 1; END;", "sqlite"), ["BEGIN", "SELECT 1", "END"])


class AtTest(unittest.TestCase):
    TEXT = "SELECT 1;\n\nSELECT 2;\n"

    def test_inside(self):
        self.assertEqual(at(self.TEXT, 3, "postgresql")[2], "SELECT 1")
        self.assertEqual(at(self.TEXT, 14, "postgresql")[2], "SELECT 2")

    def test_between_and_after(self):
        self.assertEqual(at(self.TEXT, 10, "postgresql")[2], "SELECT 1")
        self.assertEqual(at(self.TEXT, len(self.TEXT), "postgresql")[2], "SELECT 2")
        self.assertEqual(at("\n\nSELECT 3", 0, "postgresql")[2], "SELECT 3")

    def test_empty(self):
        self.assertIsNone(at("  -- nothing", 2, "postgresql"))


class KeywordTest(unittest.TestCase):
    def test_keyword(self):
        self.assertEqual(keyword("  -- c\n/* x */ (select 1) union select 2"), "SELECT")
        self.assertEqual(keyword("create table t (a int)"), "CREATE")
        self.assertEqual(keyword("# x\nshow tables"), "SHOW")
        self.assertEqual(keyword(""), "")


if __name__ == "__main__":
    unittest.main()
