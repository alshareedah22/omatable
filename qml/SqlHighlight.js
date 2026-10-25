.pragma library

// SQL to rich text for the editor's colour layer. The text layer above it
// is plain and transparent, so this only has to keep every character in
// place: whitespace is preserved and nothing is added or dropped.

var KEYWORDS = {}
;("ADD ALL ALTER ANALYZE AND ANY AS ASC AUTO_INCREMENT BEGIN BETWEEN BIGINT BOOLEAN BOTH BY CASCADE CASE CAST " +
  "CHAR CHECK COLLATE COLUMN COMMENT COMMIT CONSTRAINT CREATE CROSS CURRENT_DATE CURRENT_TIMESTAMP DATABASE " +
  "DATE DECIMAL DECLARE DEFAULT DELETE DESC DESCRIBE DISTINCT DO DOUBLE DROP ELSE END ESCAPE EXCEPT EXISTS " +
  "EXPLAIN EXTENSION FALSE FETCH FILTER FIRST FLOAT FOR FOREIGN FROM FULL FUNCTION GRANT GROUP HAVING IF ILIKE " +
  "IN INDEX INNER INSERT INT INTEGER INTERSECT INTERVAL INTO IS JOIN JSON JSONB KEY LANGUAGE LAST LATERAL LEFT " +
  "LIKE LIMIT MATERIALIZED NATURAL NOT NULL NULLS NUMERIC OFFSET ON ONLY OR ORDER OUTER OVER PARTITION PRAGMA " +
  "PRIMARY PROCEDURE RECURSIVE REFERENCES RELEASE RENAME REPLACE RESTRICT RETURNING RETURNS REVOKE RIGHT " +
  "ROLLBACK ROW ROWS SAVEPOINT SCHEMA SELECT SEQUENCE SERIAL SET SHOW SMALLINT TABLE TEMP TEMPORARY TEXT THEN " +
  "TIME TIMESTAMP TIMESTAMPTZ TO TRANSACTION TRIGGER TRUE TRUNCATE UNION UNIQUE UNSIGNED UPDATE USE USING UUID " +
  "VACUUM VALUES VARCHAR VIEW WHEN WHERE WINDOW WITH WITHOUT").split(" ").forEach(function(k) { KEYWORDS[k] = true })

// Groups: 1 comment, 2 string, 3 dollar tag, 4 quoted identifier, 5 number, 6 word.
var PATTERNS = {
  postgresql: /(--[^\n]*|\/\*[\s\S]*?(?:\*\/|$))|((?:[eE](?='))?'(?:[^']|'')*(?:'|$)|\$([A-Za-z_]\w*)?\$[\s\S]*?(?:\$\3\$|$))|("(?:[^"]|"")*(?:"|$))|(\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|([A-Za-z_][A-Za-z0-9_$]*)/g,
  mysql: /(--(?=\s|$)[^\n]*|#[^\n]*|\/\*[\s\S]*?(?:\*\/|$))|('(?:[^'\\]|''|\\[\s\S])*(?:'|$)|"(?:[^"\\]|""|\\[\s\S])*(?:"|$))()|(`(?:[^`]|``)*(?:`|$))|(\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|([A-Za-z_][A-Za-z0-9_$]*)/g,
  sqlite: /(--[^\n]*|\/\*[\s\S]*?(?:\*\/|$))|('(?:[^']|'')*(?:'|$))()|("(?:[^"]|"")*(?:"|$)|`[^`]*(?:`|$)|\[[^\]]*(?:\]|$))|(\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|([A-Za-z_][A-Za-z0-9_$]*)/g
}

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

function html(text, engine, colors) {
  var re = PATTERNS[engine === "mariadb" ? "mysql" : engine] || PATTERNS.postgresql
  re.lastIndex = 0
  var out = []
  var last = 0
  var m
  function span(color, s) { out.push('<span style="color:' + color + '">' + esc(s) + "</span>") }
  while ((m = re.exec(text)) !== null) {
    if (m[0].length === 0) { re.lastIndex++; continue }
    if (m.index > last) out.push(esc(text.substring(last, m.index)))
    if (m[1] !== undefined) span(colors.comment, m[1])
    else if (m[2] !== undefined) span(colors.string, m[2])
    else if (m[4] !== undefined) span(colors.identifier, m[4])
    else if (m[5] !== undefined) span(colors.number, m[5])
    else if (KEYWORDS[m[6].toUpperCase()]) span(colors.keyword, m[6])
    else out.push(esc(m[6]))
    last = m.index + m[0].length
  }
  if (last < text.length) out.push(esc(text.substring(last)))
  return '<div style="white-space:pre">' + out.join("") + "</div>"
}
