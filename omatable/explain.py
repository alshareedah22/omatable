"""Query plans, turned into one tree shape for the window.

A node is {label, detail: [[name, value], ...], cost, rows, actual_rows,
time_ms, loops, children}. cost, rows and the actual_* fields are None when
the engine does not report them.
"""

import json
import re

from .protocol import Error

PG_DETAIL = ("Join Type", "Index Name", "Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Filter",
             "Join Filter", "Sort Key", "Sort Method", "Group Key", "Strategy", "Rows Removed by Filter",
             "Heap Fetches", "Shared Hit Blocks", "Shared Read Blocks", "Workers Planned", "Workers Launched",
             "Subplan Name", "Parent Relationship", "CTE Name", "Function Name", "Output")


def node(label, detail=(), cost=None, rows=None, actual_rows=None, time_ms=None, loops=None, children=None):
    return {"label": label, "detail": [[k, v] for k, v in detail], "cost": cost, "rows": rows,
            "actual_rows": actual_rows, "time_ms": time_ms, "loops": loops, "children": children or []}


def _text(v):
    if isinstance(v, (list, tuple)):
        return ", ".join(str(x) for x in v)
    return str(v)


# ---- PostgreSQL: EXPLAIN (FORMAT JSON) ---------------------------------------

def postgres(data):
    if isinstance(data, str):
        data = json.loads(data)
    top = data[0] if isinstance(data, list) else data

    def walk(p):
        label = p.get("Node Type", "?")
        if p.get("Relation Name"):
            label += " on " + p["Relation Name"]
            if p.get("Alias") and p["Alias"] != p["Relation Name"]:
                label += " " + p["Alias"]
        elif p.get("CTE Name"):
            label += " on " + p["CTE Name"]
        loops = p.get("Actual Loops")
        time_ms = p.get("Actual Total Time")
        return node(label, [(k, _text(p[k])) for k in PG_DETAIL if k in p and p[k] not in (None, "", [])],
                    cost=p.get("Total Cost"), rows=p.get("Plan Rows"), actual_rows=p.get("Actual Rows"),
                    time_ms=time_ms * loops if time_ms is not None and loops else time_ms, loops=loops,
                    children=[walk(c) for c in p.get("Plans") or ()])
    summary = {"planning_ms": top.get("Planning Time"), "execution_ms": top.get("Execution Time")}
    return {"nodes": [walk(top["Plan"])], "summary": summary}


# ---- MySQL: EXPLAIN FORMAT=TREE / EXPLAIN ANALYZE (text) ----------------------

TREE_LINE = re.compile(r"^(\s*)-> (.*)$")
COST = re.compile(r"\(cost=([\d.e+]+)(?:\.\.([\d.e+]+))? rows=([\d.e+]+)\)")
ACTUAL = re.compile(r"\(actual time=([\d.e+]+)\.\.([\d.e+]+) rows=([\d.e+]+) loops=(\d+)\)")


def _num(s):
    try:
        f = float(s)
    except (TypeError, ValueError):
        return None
    return int(f) if f.is_integer() else f


def mysql_tree(text):
    roots, stack = [], []
    for line in str(text).splitlines():
        m = TREE_LINE.match(line)
        if not m:
            if stack and line.strip():
                stack[-1][1]["detail"].append(["", line.strip()])
            continue
        indent, body = len(m.group(1)), m.group(2)
        cost = COST.search(body)
        actual = ACTUAL.search(body)
        label = COST.sub("", ACTUAL.sub("", body)).strip()
        n = node(label, cost=_num(cost.group(2) or cost.group(1)) if cost else None,
                 rows=_num(cost.group(3)) if cost else None,
                 actual_rows=_num(actual.group(3)) if actual else None,
                 time_ms=_num(actual.group(2)) * int(actual.group(4)) if actual else None,
                 loops=int(actual.group(4)) if actual else None)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        (stack[-1][1]["children"] if stack else roots).append(n)
        stack.append((indent, n))
    if not roots:
        raise Error("invalid", "the server returned no plan")
    return {"nodes": roots, "summary": {}}


# ---- MariaDB (and MySQL without TREE): EXPLAIN/ANALYZE FORMAT=JSON --------------

MY_DETAIL = ("access_type", "possible_keys", "key", "used_key_parts", "ref", "filtered", "r_filtered",
             "attached_condition", "using_index", "using_filesort", "using_temporary_table", "loops", "r_loops")
CONTAINERS = ("nested_loop", "union_result", "query_specifications", "subqueries", "materialized_from_subquery",
              "ordering_operation", "grouping_operation", "duplicates_removal", "filesort", "temporary_table",
              "block-nl-join", "having_condition", "window_functions_computation", "buffer_type")


def mysql_json(data):
    if isinstance(data, str):
        data = json.loads(data)

    def cost_of(d):
        ci = d.get("cost_info") or {}
        for k in ("prefix_cost", "query_cost", "read_cost"):
            if k in ci:
                return _num(ci[k])
        return _num(d.get("cost"))

    def walk(key, d):
        if isinstance(d, list):
            return [n for item in d for n in walk(key, item)]
        if not isinstance(d, dict):
            return []
        if "table" in d and isinstance(d["table"], dict) and key != "table":
            # a wrapper such as {"table": {...}} inside nested_loop
            return walk("table", d["table"])
        children = []
        for k, v in d.items():
            if k in ("table",) and isinstance(v, dict):
                children += walk("table", v)
            elif k in CONTAINERS or k.endswith("_operation") or k in ("query_block", "query_specifications"):
                children += walk(k, v)
            elif isinstance(v, dict) and ("table" in v or "query_block" in v or "nested_loop" in v):
                children += walk(k, v)
        if key == "table":
            label = f"{d.get('access_type', 'scan')} on {d.get('table_name', '?')}"
            rows = _num(d.get("rows_examined_per_scan", d.get("rows")))
            detail = [(k, _text(d[k])) for k in MY_DETAIL if k in d]
            return [node(label, detail, cost=cost_of(d), rows=rows, actual_rows=_num(d.get("r_rows")),
                         time_ms=_num(d.get("r_total_time_ms")), children=children)]
        label = key.replace("_", " ")
        if key == "query_block" and d.get("select_id") is not None:
            label += f" #{d['select_id']}"
        if not children and not cost_of(d):
            return []
        return [node(label, [(k, _text(d[k])) for k in MY_DETAIL if k in d], cost=cost_of(d),
                     time_ms=_num(d.get("r_total_time_ms")), children=children)]
    nodes = walk("query_block", data.get("query_block", data))
    if not nodes:
        raise Error("invalid", "the server returned no plan")
    return {"nodes": nodes, "summary": {}}


# ---- SQLite: EXPLAIN QUERY PLAN rows (id, parent, notused, detail) --------------

def sqlite(rows):
    nodes, roots = {}, []
    for row in rows:
        nid, parent, detail = row[0], row[1], row[-1]
        n = node(str(detail))
        nodes[nid] = n
        (nodes[parent]["children"] if parent in nodes else roots).append(n)
    if not roots:
        raise Error("invalid", "the server returned no plan")
    return {"nodes": roots, "summary": {}}
