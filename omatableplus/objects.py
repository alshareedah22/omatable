"""Views, functions and triggers: templates for new ones.

Definitions of existing objects come from each adapter (definition());
these are the starting points the editor opens for a new one.
"""

from .protocol import Error

KINDS = ("view", "function", "trigger")


def template(d, schema, kind, table=None):
    if kind not in KINDS:
        raise Error("invalid", f"unknown object kind {kind!r}")
    table = table or "some_table"
    t = d.table(schema, table)
    q = d.quote
    if d.name == "postgresql":
        if kind == "view":
            return f"CREATE VIEW {d.table(schema, 'new_view')} AS\nSELECT\n  *\nFROM {t};"
        if kind == "function":
            return (f"CREATE OR REPLACE FUNCTION {d.table(schema, 'new_function')}(a integer)\n"
                    "RETURNS integer\nLANGUAGE plpgsql\nAS $$\nBEGIN\n  RETURN a + 1;\nEND;\n$$;")
        fn = d.table(schema, f"{table}_before_update")
        return (f"-- the trigger runs this function for each row; NEW is the row being written\n"
                f"CREATE OR REPLACE FUNCTION {fn}()\nRETURNS trigger\nLANGUAGE plpgsql\nAS $$\nBEGIN\n"
                f"  RETURN NEW;\nEND;\n$$;\n\n"
                f"CREATE TRIGGER {q(table + '_before_update')}\nBEFORE UPDATE ON {t}\nFOR EACH ROW EXECUTE FUNCTION {fn}();")
    if d.name == "mysql":
        if kind == "view":
            return f"CREATE VIEW {d.table(schema, 'new_view')} AS\nSELECT\n  *\nFROM {t};"
        if kind == "function":
            return (f"CREATE FUNCTION {d.table(schema, 'new_function')}(a INT)\nRETURNS INT\nDETERMINISTIC\n"
                    "BEGIN\n  RETURN a + 1;\nEND;")
        return (f"CREATE TRIGGER {d.table(schema, table + '_before_update')}\nBEFORE UPDATE ON {t}\nFOR EACH ROW\n"
                "BEGIN\n  -- NEW is the row being written, e.g. SET NEW.updated_at = NOW();\nEND;")
    if kind == "function":
        raise Error("unsupported", "SQLite has no stored functions")
    if kind == "view":
        return f"CREATE VIEW {q('new_view')} AS\nSELECT\n  *\nFROM {q(table)};"
    return (f"CREATE TRIGGER {q(table + '_after_insert')}\nAFTER INSERT ON {q(table)}\nBEGIN\n"
            "  -- NEW is the inserted row\n  SELECT 1;\nEND;")
