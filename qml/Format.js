.pragma library

// SQL formatter for the editor: keywords upper-case, one clause per line,
// select lists and AND/OR conditions one per line, subqueries indented.
// Strings, quoted names and comments are copied exactly as written.

var KEYWORDS = {}
;("ADD ALL ALTER AND ANY AS ASC BEGIN BETWEEN BY CASCADE CASE CAST CHECK COLLATE COLUMN COMMIT CONFLICT " +
  "CONSTRAINT CREATE CROSS CURRENT_DATE CURRENT_TIMESTAMP DATABASE DEFAULT DELETE DESC DISTINCT DO DROP ELSE END " +
  "ESCAPE EXCEPT EXISTS EXPLAIN FALSE FETCH FILTER FIRST FOR FOREIGN FROM FULL FUNCTION GRANT GROUP HAVING IF " +
  "ILIKE IN INDEX INNER INSERT INTERSECT INTERVAL INTO IS JOIN KEY LAST LATERAL LEFT LIKE LIMIT NATURAL NOT " +
  "NOTHING NULL NULLS OFFSET ON ONLY OR ORDER OUTER OVER PARTITION PRIMARY RECURSIVE REFERENCES RETURNING " +
  "REVOKE RIGHT ROLLBACK ROW ROWS SCHEMA SELECT SET TABLE THEN TO TRUE TRUNCATE UNION UNIQUE UPDATE USING " +
  "VALUES VIEW WHEN WHERE WINDOW WITH").split(" ").forEach(function(k) { KEYWORDS[k] = true })

// Clauses that start a new line at the statement's indentation.
var CLAUSES = ["SELECT", "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "OFFSET", "FETCH",
  "UNION ALL", "UNION", "EXCEPT", "INTERSECT", "VALUES", "SET", "RETURNING", "WINDOW", "INSERT INTO",
  "DELETE FROM", "UPDATE", "ON CONFLICT", "WITH",
  "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
  "INNER JOIN", "CROSS JOIN", "NATURAL JOIN", "JOIN"]
// Clauses whose comma-separated items go one per line.
var LISTS = { "SELECT": 1, "GROUP BY": 1, "ORDER BY": 1, "SET": 1, "RETURNING": 1 }
var IND = "  "

function tokenize(text) {
  var re = /(--[^\n]*|#[^\n]*|\/\*[\s\S]*?(?:\*\/|$))|('(?:[^'\\]|''|\\[\s\S])*(?:'|$)|\$([A-Za-z_]\w*)?\$[\s\S]*?(?:\$\3\$|$))|("(?:[^"]|"")*(?:"|$)|`(?:[^`]|``)*(?:`|$)|\[[^\]]*(?:\]|$))|(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|([A-Za-z_][A-Za-z0-9_$]*)|(::|<=|>=|<>|!=|\|\||->>|->|[(),;.=<>+\-*\/%])|(\s+)|([\s\S])/g
  var out = []
  var m
  while ((m = re.exec(text)) !== null) {
    if (m[1] !== undefined) out.push({ t: "comment", v: m[1] })
    else if (m[2] !== undefined) out.push({ t: "string", v: m[2] })
    else if (m[4] !== undefined) out.push({ t: "quoted", v: m[4] })
    else if (m[5] !== undefined) out.push({ t: "number", v: m[5] })
    else if (m[6] !== undefined) out.push({ t: "word", v: m[6], u: m[6].toUpperCase() })
    else if (m[7] !== undefined) out.push({ t: "punct", v: m[7] })
    else if (m[8] !== undefined) { if (m[8].indexOf("\n\n") >= 0 && out.length) out.push({ t: "blank" }) }
    else out.push({ t: "other", v: m[9] })
  }
  return out
}

// The clause (possibly several words) starting at token i, or "".
function clauseAt(tokens, i) {
  if (tokens[i].t !== "word") return ""
  for (var c = 0; c < CLAUSES.length; c++) {
    var parts = CLAUSES[c].split(" ")
    var ok = true
    for (var k = 0; k < parts.length; k++) {
      var tk = tokens[i + k]
      if (!tk || tk.t !== "word" || tk.u !== parts[k]) { ok = false; break }
    }
    if (ok) return CLAUSES[c]
  }
  return ""
}

function format(text) {
  var tokens = tokenize(text)
  var out = ""
  var depth = 0          // indentation level of the current statement or subquery
  var stack = []         // for each open paren: { sub: is a subquery, depth before }
  var clause = ""        // the clause we are in, at this level
  var clauseStack = []
  var lineStart = true
  var inBetween = false

  function newline(level) {
    out = out.replace(/[ \t]+$/, "")
    if (out.length && out.charAt(out.length - 1) !== "\n") out += "\n"
    for (var i = 0; i < level; i++) out += IND
    lineStart = true
  }
  function emit(s, spaceBefore) {
    if (!lineStart && spaceBefore && !/[\s(]$/.test(out)) out += " "
    out += s
    lineStart = false
  }

  for (var i = 0; i < tokens.length; i++) {
    var tk = tokens[i]
    var prev = i > 0 ? tokens[i - 1] : null
    if (tk.t === "blank") continue
    if (tk.t === "comment") {
      emit(tk.v, true)
      if (tk.v.charAt(0) !== "/") newline(depth + (clause ? 1 : 0))
      continue
    }
    var c = clauseAt(tokens, i)
    if (c) {
      newline(depth)
      emit(c, false)
      i += c.split(" ").length - 1
      clause = c
      if (LISTS[c] || c === "SELECT") {
        // SELECT DISTINCT stays on the line; items go below
        if (tokens[i + 1] && tokens[i + 1].t === "word" && tokens[i + 1].u === "DISTINCT") { emit("DISTINCT", true); i++ }
        newline(depth + 1)
      } else {
        emit("", false)
        out += " "
        lineStart = true
      }
      continue
    }
    if (tk.t === "word" && (tk.u === "AND" || tk.u === "OR") && clause !== "" && !inBetween &&
        (clause === "WHERE" || clause === "HAVING" || clause.indexOf("JOIN") >= 0)) {
      newline(depth + 1)
      emit(tk.u, false)
      continue
    }
    if (tk.t === "word" && tk.u === "ON" && clause.indexOf("JOIN") >= 0) { emit("ON", true); continue }
    if (tk.t === "punct") {
      var v = tk.v
      if (v === "(") {
        var sub = tokens[i + 1] && tokens[i + 1].t === "word" && (tokens[i + 1].u === "SELECT" || tokens[i + 1].u === "WITH")
        var call = prev && (prev.t === "word" && !KEYWORDS[prev.u] || prev.t === "quoted") && clause !== "INSERT INTO"
        emit("(", !call)
        stack.push({ sub: sub, depth: depth })
        clauseStack.push(clause)
        if (sub) { depth += 1; clause = "" }
        else clause = "()" + clause
        continue
      }
      if (v === ")") {
        var open = stack.pop() || { sub: false, depth: depth }
        if (open.sub) newline(open.depth + 1)
        depth = open.depth
        clause = clauseStack.length ? clauseStack.pop() : ""
        out = out.replace(/[ \t]+$/, "")
        emit(")", false)
        continue
      }
      if (v === ",") {
        out = out.replace(/[ \t]+$/, "")
        out += ","
        if (LISTS[clause]) newline(depth + 1)
        else { out += " "; lineStart = true }
        continue
      }
      if (v === ";") {
        out = out.replace(/[ \t]+$/, "")
        out += ";"
        depth = 0; stack = []; clause = ""; clauseStack = []
        newline(0)
        if (i + 1 < tokens.length) out += "\n"
        continue
      }
      if (v === "." || v === "::") { out = out.replace(/[ \t]+$/, ""); out += v; lineStart = true; continue }
      emit(v, true)
      continue
    }
    if (tk.t === "word") {
      if (tk.u === "BETWEEN") inBetween = true
      else if (tk.u === "AND" && inBetween) inBetween = false
      var afterDot = prev && prev.t === "punct" && (prev.v === "." || prev.v === "::")
      var word = KEYWORDS[tk.u] && !afterDot ? tk.u : tk.v
      if (afterDot) { out += word; lineStart = false } else emit(word, true)
      continue
    }
    if (prev && prev.t === "punct" && (prev.v === "." || prev.v === "::")) { out += tk.v; lineStart = false; continue }
    emit(tk.v, true)
  }
  return out.replace(/[ \t]+$/gm, "").replace(/^\n+/, "").replace(/\n{3,}/g, "\n\n").replace(/\s+$/, "")
}
