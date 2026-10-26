// Run by tests/test_complete.py with node.
const assert = require("assert")
const F = (() => {
  const fs = require("fs"), path = require("path")
  const src = fs.readFileSync(path.join(__dirname, "../../qml/Format.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
  return new Function(src + "\nreturn { format, tokenize }")()
})()
const f = F.format

function show(s) { console.log(f(s)); console.log("----") }
if (process.argv[2] === "show") {
  show("select id, name, count(*) as n from people p left join teams t on t.id = p.team_id and t.active where p.age > 30 and (p.city = 'x' or p.city='y') group by id, name order by n desc limit 10")
  show("insert into t (a,b) values (1,'it''s'), (2, 'b');update t set a=1, b=2 where id in (select id from u where x between 1 and 5) returning *")
  show("SELECT \"Mixed Name\", data->>'k', x::text FROM s.t -- note\nWHERE y = $$a;b$$")
  process.exit(0)
}

assert.strictEqual(f("select id, name from people where age > 30 and city = 'x' order by name"),
  "SELECT\n  id,\n  name\nFROM people\nWHERE age > 30\n  AND city = 'x'\nORDER BY\n  name")
// strings, quoted names, comments and casts are kept exactly
assert.strictEqual(f("select 'a  b;c', \"Mixed  Case\", x::text from t -- keep  me\n"),
  "SELECT\n  'a  b;c',\n  \"Mixed  Case\",\n  x::text\nFROM t -- keep  me")
// joins on their own line, ON stays, AND under it
assert.strictEqual(f("select * from a join b on a.id = b.a_id and b.ok left join c on c.id = a.c"),
  "SELECT\n  *\nFROM a\nJOIN b ON a.id = b.a_id\n  AND b.ok\nLEFT JOIN c ON c.id = a.c")
// subqueries are indented; function calls keep their parentheses tight
assert.strictEqual(f("select count(*) from t where id in (select id from u where x = 1)"),
  "SELECT\n  count(*)\nFROM t\nWHERE id IN (\n  SELECT\n    id\n  FROM u\n  WHERE x = 1\n)")
// BETWEEN … AND is not split
assert.strictEqual(f("select 1 from t where x between 1 and 5 and y = 2"),
  "SELECT\n  1\nFROM t\nWHERE x BETWEEN 1 AND 5\n  AND y = 2")
// several statements, a blank line between them
assert.strictEqual(f("insert into t (a, b) values (1, 2); delete from t where a = 1;"),
  "INSERT INTO t (a, b)\nVALUES (1, 2);\n\nDELETE FROM t\nWHERE a = 1;")
// dollar quotes and identifiers that look like keywords after a dot
assert.strictEqual(f("select t.order from t where body = $x$ select from $x$"),
  "SELECT\n  t.order\nFROM t\nWHERE body = $x$ select from $x$")
// formatting twice changes nothing
const once = f("select a, b from t where x = 1 and y in (select z from w) group by a, b")
assert.strictEqual(f(once), once)
console.log("ok")
