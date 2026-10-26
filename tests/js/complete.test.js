// Run by tests/test_complete.py with node: Complete.js is loaded without its
// QML pragma, then these checks run and print "ok" or throw.
const assert = require("assert")
const C = loadComplete()

const CAT = [
  { schema: "public", name: "people", kind: "table", columns: [{ name: "id", type: "integer" }, { name: "name", type: "text" }, { name: "team_id", type: "integer" }] },
  { schema: "public", name: "teams", kind: "table", columns: [{ name: "id", type: "integer" }, { name: "title", type: "text" }] },
  { schema: "public", name: "Mixed Case", kind: "view", columns: [{ name: "Value", type: "text" }] },
  { schema: "audit", name: "log", kind: "table", columns: [{ name: "at", type: "timestamptz" }] },
]
function at(sql) { const i = sql.indexOf("|"); return C.suggest(sql.replace("|", ""), i, CAT, "postgresql") }
function labels(sql) { return at(sql).items.map(i => i.label) }

// tables after FROM / JOIN, schemas offered when there are several
assert.deepStrictEqual(labels("SELECT * FROM pe|"), ["people"])
assert.ok(labels("SELECT * FROM |").includes("teams"))
assert.ok(labels("SELECT * FROM |").includes("audit"))
assert.deepStrictEqual(labels("select * from people p join t|"), ["teams"])
assert.deepStrictEqual(labels("SELECT * FROM people, t|"), ["teams"])
assert.deepStrictEqual(labels("UPDATE te|"), ["teams"])
// schema. → its tables; alias. and table. → columns
assert.deepStrictEqual(labels("SELECT * FROM audit.|"), ["log"])
assert.deepStrictEqual(labels("SELECT p.| FROM people p"), ["id", "name", "team_id"])
assert.deepStrictEqual(labels("SELECT p.n| FROM people AS p"), ["name"])
assert.deepStrictEqual(labels("SELECT people.ti| FROM people"), [])
assert.deepStrictEqual(labels("SELECT t.ti| FROM people p JOIN teams t ON t.id = p.team_id"), ["title"])
// bare words: columns of the tables in the statement first, then tables and keywords
const bare = labels("SELECT na| FROM people")
assert.strictEqual(bare[0], "name")
assert.deepStrictEqual(labels("SELECT id FROM people WHERE team|"), ["team_id", "teams"])
assert.ok(labels("SEL|").includes("SELECT"))
assert.strictEqual(labels("sel|")[0], "SELECT")
// an underscore part matches too: "id" finds team_id after id
assert.deepStrictEqual(labels("SELECT * FROM people WHERE id|").slice(0, 2), ["id", "team_id"])
// only the statement under the cursor counts
assert.deepStrictEqual(labels("SELECT * FROM teams; SELECT ti| FROM people").filter(l => l === "title"), [])
// replacement range and quoting
const r = at("SELECT * FROM Mix|")
assert.deepStrictEqual([r.start, r.end, r.items[0].insert], [14, 17, '"Mixed Case"'])
assert.strictEqual(at('SELECT "Mixed Case".| FROM x').items[0].insert, '"Value"')
assert.strictEqual(C.quote("order", "mysql"), "`order`")
assert.strictEqual(C.quote("Name", "mysql"), "Name")
assert.strictEqual(C.quote("Name", "postgresql"), '"Name"')
// nothing typed: the columns in scope, or nothing at all
assert.deepStrictEqual(labels("SELECT * FROM people WHERE |"), ["id", "name", "team_id"])  // Ctrl+Space with nothing typed
assert.deepStrictEqual(labels("|"), [])
// exact single match is not offered again
assert.deepStrictEqual(labels("SELECT * FROM teams|"), [])
console.log("ok")

function loadComplete() {
  const fs = require("fs"), path = require("path")
  const src = fs.readFileSync(path.join(__dirname, "../../qml/Complete.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
  return new Function(src + "\nreturn { suggest, context, references, quote, statementAt }")()
}
