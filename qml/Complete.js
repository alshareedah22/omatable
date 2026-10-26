.pragma library

// SQL autocomplete for the editor: given the text, the cursor and the
// catalog (tables with their columns), what to suggest and what to replace.
// Suggestions depend on where the cursor is: after FROM/JOIN/UPDATE/INTO a
// table, after "x." a column of the table or alias x (or a table of schema x),
// anywhere else the columns of the tables the statement uses, then tables
// and keywords.

var KEYWORDS = ("SELECT FROM WHERE AND OR NOT NULL IS IN LIKE ILIKE BETWEEN EXISTS INSERT INTO VALUES UPDATE SET " +
  "DELETE CREATE TABLE VIEW INDEX DROP ALTER ADD COLUMN PRIMARY KEY FOREIGN REFERENCES UNIQUE DEFAULT CHECK " +
  "JOIN LEFT RIGHT INNER OUTER FULL CROSS ON USING GROUP BY ORDER ASC DESC HAVING LIMIT OFFSET DISTINCT AS " +
  "CASE WHEN THEN ELSE END UNION ALL EXCEPT INTERSECT WITH RETURNING TRUNCATE BEGIN COMMIT ROLLBACK " +
  "COUNT SUM AVG MIN MAX COALESCE CAST NOW TRUE FALSE EXPLAIN DATABASE SCHEMA").split(" ")

// After these words the next name is a table.
var TABLE_AFTER = { FROM: 1, JOIN: 1, UPDATE: 1, INTO: 1, TABLE: 1, TRUNCATE: 1, DESCRIBE: 1 }
var NOT_ALIAS = { WHERE: 1, ON: 1, USING: 1, JOIN: 1, LEFT: 1, RIGHT: 1, INNER: 1, OUTER: 1, FULL: 1, CROSS: 1,
  GROUP: 1, ORDER: 1, LIMIT: 1, SET: 1, VALUES: 1, HAVING: 1, UNION: 1, WINDOW: 1, OFFSET: 1, RETURNING: 1,
  NATURAL: 1, AS: 1, SELECT: 1, FROM: 1, AND: 1, OR: 1 }
var NAME = "(?:\"(?:[^\"]|\"\")+\"|`(?:[^`]|``)+`|[A-Za-z_][A-Za-z0-9_$]*)"
var LIMIT = 60

function unquote(name) {
  if (!name) return ""
  var c = name.charAt(0)
  if ((c === '"' || c === "`") && name.length > 1 && name.charAt(name.length - 1) === c)
    return name.substring(1, name.length - 1).split(c + c).join(c)
  return name
}

// The statement the cursor is in: from the last ; before it to the next ; after it.
function statementAt(text, cursor) {
  var start = text.lastIndexOf(";", cursor - 1) + 1
  var end = text.indexOf(";", cursor)
  return { text: text.substring(start, end < 0 ? text.length : end), offset: start }
}

// The word being typed, the qualifier before a dot, and the keyword before it.
function context(text, cursor) {
  var before = text.substring(0, cursor)
  var m = /(?:("(?:[^"]|"")*"|`(?:[^`]|``)*`|[A-Za-z_][A-Za-z0-9_$]*)\.)?(["`]?[A-Za-z0-9_$]*)$/.exec(before)
  var word = m[2] || ""
  var qualifier = m[1] !== undefined ? unquote(m[1]) : ""
  var start = cursor - word.length
  var rest = before.substring(0, m.index).replace(/\s+$/, "")
  var prev = /([A-Za-z_]+)$/.exec(rest)
  var lastChar = rest.charAt(rest.length - 1)
  return { word: word, prefix: word.replace(/^["`]/, ""), qualifier: qualifier, start: start,
           previous: prev && rest.length === prev.index + prev[1].length ? prev[1].toUpperCase() : "",
           afterComma: lastChar === ",", dot: m[1] !== undefined }
}

// Tables the statement names, with their aliases: [{ schema, table, alias }].
function references(sql) {
  var re = new RegExp("\\b(?:FROM|JOIN|UPDATE|INTO)\\s+(" + NAME + ")(?:\\.(" + NAME + "))?(?:\\s+(?:AS\\s+)?(" + NAME + "))?" +
                      "|,\\s*(" + NAME + ")(?:\\.(" + NAME + "))?(?:\\s+(?:AS\\s+)?(" + NAME + "))?", "gi")
  var out = []
  var m
  while ((m = re.exec(sql)) !== null) {
    var a = m[1] !== undefined ? [m[1], m[2], m[3]] : [m[4], m[5], m[6]]
    if (a[0] === undefined) continue
    var schema = a[1] !== undefined ? unquote(a[0]) : ""
    var table = unquote(a[1] !== undefined ? a[1] : a[0])
    var alias = a[2] !== undefined && !NOT_ALIAS[a[2].toUpperCase()] ? unquote(a[2]) : ""
    out.push({ schema: schema, table: table, alias: alias })
  }
  return out
}

function findTable(catalog, schema, name) {
  var lower = name.toLowerCase()
  var loose = null
  for (var i = 0; i < catalog.length; i++) {
    var t = catalog[i]
    if (schema && t.schema !== schema && t.schema.toLowerCase() !== schema.toLowerCase()) continue
    if (t.name === name) return t
    if (!loose && t.name.toLowerCase() === lower) loose = t
  }
  return loose
}

// Quote a name only when it has to be: not lower-case snake, or a keyword.
function quote(name, engine) {
  var plain = engine === "postgresql" ? /^[a-z_][a-z0-9_$]*$/ : /^[A-Za-z_][A-Za-z0-9_$]*$/
  if (plain.test(name) && KEYWORDS.indexOf(name.toUpperCase()) < 0) return name
  var q = engine === "mysql" || engine === "mariadb" ? "`" : '"'
  return q + name.split(q).join(q + q) + q
}

function rank(label, prefix) {
  if (!prefix) return 1
  var l = label.toLowerCase()
  var p = prefix.toLowerCase()
  if (l.indexOf(p) === 0) return l === p ? 0 : 1
  return l.indexOf("_" + p) >= 0 ? 2 : -1
}

// What to suggest: { start, end, items: [{ label, insert, kind, detail }] }.
function suggest(text, cursor, catalog, engine) {
  catalog = catalog || []
  var ctx = context(text, cursor)
  var stmt = statementAt(text, cursor)
  var refs = references(stmt.text)
  var items = []
  var seen = {}
  function add(label, kind, detail, insert) {
    var key = kind + ":" + label
    if (seen[key]) return
    var r = rank(label, ctx.prefix)
    if (r < 0) return
    seen[key] = true
    items.push({ label: label, kind: kind, detail: detail || "", insert: insert || label, r: r, order: items.length })
  }
  function columnsOf(t, detail) {
    for (var i = 0; i < t.columns.length; i++)
      add(t.columns[i].name, "column", detail ? t.name + " · " + t.columns[i].type : t.columns[i].type, quote(t.columns[i].name, engine))
  }
  function tables(schema) {
    var many = {}
    for (var i = 0; i < catalog.length; i++) many[catalog[i].schema] = 1
    var qualify = !schema && Object.keys(many).length > 1
    for (var j = 0; j < catalog.length; j++) {
      var t = catalog[j]
      if (schema && t.schema !== schema) continue
      add(t.name, t.kind, t.schema, quote(t.name, engine))
    }
    if (qualify) for (var s in many) add(s, "schema", "", quote(s, engine))
  }

  if (ctx.dot) {
    var q = ctx.qualifier
    var hit = null
    for (var i = 0; i < refs.length && !hit; i++)
      if (refs[i].alias && refs[i].alias.toLowerCase() === q.toLowerCase()) hit = findTable(catalog, refs[i].schema, refs[i].table)
    if (!hit) hit = findTable(catalog, "", q)
    if (hit) columnsOf(hit, false)
    else tables(q)
  } else if (TABLE_AFTER[ctx.previous] || (ctx.afterComma && /\bFROM\b[^()]*$/i.test(text.substring(stmt.offset, ctx.start)) &&
                                          !/\b(WHERE|GROUP|ORDER|HAVING|LIMIT|SET|ON)\b[^()]*$/i.test(text.substring(stmt.offset, ctx.start)))) {
    tables("")
  } else {
    if (!ctx.prefix && !ctx.afterComma && ctx.previous === "") return { start: ctx.start, end: cursor, items: [] }
    var used = []
    for (var k = 0; k < refs.length; k++) {
      var t = findTable(catalog, refs[k].schema, refs[k].table)
      if (t && used.indexOf(t) < 0) used.push(t)
    }
    for (var u = 0; u < used.length; u++) columnsOf(used[u], used.length > 1)
    if (ctx.prefix) {
      tables("")
      for (var w = 0; w < KEYWORDS.length; w++) add(KEYWORDS[w], "keyword")
    }
  }
  items.sort(function(a, b) { return a.r - b.r || a.order - b.order })
  // nothing to offer when the only suggestion is exactly what is typed
  if (items.length === 1 && items[0].label === ctx.prefix) items = []
  return { start: ctx.start, end: cursor, items: items.slice(0, LIMIT) }
}
