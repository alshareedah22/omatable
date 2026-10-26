import QtQuick
import Quickshell
import qs.Commons
import "Values.js" as Values

// One query result behind the DataGrid interface, sorted in memory. Results
// of a plain one-table SELECT (result.source from the helper) can be edited:
// cell edits and deletions are staged like a table tab's and committed by
// ResultTabs through table.commit.
Item {
  id: m

  property var result: null
  property var columns: []
  property var rows: []
  property var visibleColumns: []
  property var colWidths: []
  property var sort: []
  property string engine: ""
  readonly property var source: result && result.source ? result.source : null
  readonly property bool readOnly: source === null
  readonly property bool editable: source !== null
  property var edits: ({})       // row -> { column index: value }
  property var deleted: ({})     // row -> true
  readonly property int changeCount: { revision; return Object.keys(edits).length + Object.keys(deleted).length }
  readonly property bool dirty: changeCount > 0
  readonly property bool loading: false
  readonly property string error: ""
  readonly property int offset: 0
  property int revision: 0
  readonly property int rowCount: rows.length
  property int selRow: -1
  property int selCol: 0

  signal notify(string text)

  onResultChanged: {
    columns = result && result.columns ? result.columns.map(function(c) {
      return { name: c.name, type: c.type || "", pk: false, nullable: true, default: null }
    }) : []
    rows = result && result.rows ? result.rows.slice() : []
    edits = ({})
    deleted = ({})
    sort = []
    selRow = rows.length ? 0 : -1
    selCol = 0
    layoutColumns()
  }

  function layoutColumns() {
    const vis = [], widths = []
    const charW = Style.font.body * 0.62
    for (let i = 0; i < columns.length; i++) {
      vis.push(i)
      let w = columns[i].name.length * charW + 40
      for (let r = 0; r < Math.min(rows.length, 60); r++) w = Math.max(w, display(rows[r][i]).length * charW + 20)
      widths.push(Math.round(Math.max(70, Math.min(360, w))))
    }
    visibleColumns = vis
    colWidths = widths
  }

  function resizeColumn(vi, w) {
    const copy = colWidths.slice()
    copy[vi] = Math.max(40, Math.round(w))
    colWidths = copy
  }

  function display(v) { return Values.display(v) }
  function editText(v) { return Values.editText(v) }
  function cellValue(r, c) {
    const e = edits[r]
    if (e && (c in e)) return e[c]
    return rows[r] ? rows[r][c] : null
  }
  function isEdited(r, c) { return !!edits[r] && (c in edits[r]) }
  function rowState(r) { return deleted[r] ? "deleted" : edits[r] ? "edited" : "" }
  function canEdit(r) {
    if (!source) { notify("Read-only: only a plain SELECT of one table that includes its primary key can be edited here"); return false }
    if (r < 0 || r >= rows.length) { notify("Insert rows from the table's own tab"); return false }
    if (deleted[r]) { notify("Restore the row before editing it"); return false }
    return true
  }
  function setCell(r, c, value) {
    if (!canEdit(r)) return
    const orig = rows[r][c]
    const same = value === null ? orig === null : (orig !== null && editText(orig) === value)
    const e = edits[r] || {}
    if (same) delete e[c]; else e[c] = value
    if (Object.keys(e).length) edits[r] = e; else delete edits[r]
    revision++
  }
  function toggleDelete(r) {
    if (!canEdit(r) && !deleted[r]) return
    if (deleted[r]) delete deleted[r]; else { deleted[r] = true; delete edits[r] }
    revision++
  }
  function addRow() { canEdit(-1) }
  function discardAll() { edits = ({}); deleted = ({}); revision++ }

  function keyOf(r) {
    const k = {}
    for (const name of source.key) k[name] = rows[r][columns.findIndex(function(c) { return c.name === name })]
    return k
  }
  // {updates, deletes} in table.commit's shape
  function changes() {
    const out = { updates: [], deletes: [] }
    for (const r in deleted) out.deletes.push({ key: keyOf(r) })
    for (const r in edits) {
      const values = {}
      for (const c in edits[r]) values[columns[c].name] = edits[r][c]
      out.updates.push({ key: keyOf(r), values: values })
    }
    return out
  }
  // After a commit: the edited values become the rows, deleted rows go away.
  function applied() {
    const keep = []
    for (let r = 0; r < rows.length; r++) {
      if (deleted[r]) continue
      const row = rows[r].slice()
      const e = edits[r]
      if (e) for (const c in e) row[c] = e[c] !== null && typeof e[c] === "object" && e[c].$t === "default" ? null : e[c]
      keep.push(row)
    }
    rows = keep
    edits = ({})
    deleted = ({})
    selRow = Math.min(selRow, rows.length - 1)
    revision++
  }
  function openEditor(r, c) { editorRequested(r, c) }
  signal editorRequested(int r, int c)
  function select(r, vi) { selRow = r; selCol = vi }

  function toggleSort(name, add) {
    if (dirty) { notify("Commit or discard the edits before sorting"); return }
    const c = columns.findIndex(function(x) { return x.name === name })
    const desc = sort.length && sort[0].column === name && !sort[0].desc
    sort = [{ column: name, desc: desc }]
    const sign = desc ? -1 : 1
    rows = rows.slice().sort(function(a, b) {
      const x = a[c], y = b[c]
      if (x === y) return 0
      if (x === null) return 1
      if (y === null) return -1
      if (typeof x === "number" && typeof y === "number") return (x - y) * sign
      return String(x).localeCompare(String(y), undefined, { numeric: true }) * sign
    })
    revision++
  }

  function sortMark(name) {
    return sort.length && sort[0].column === name ? (sort[0].desc ? "▼" : "▲") : ""
  }

  function copyText(text) { Quickshell.execDetached(["wl-copy", "--", text]) }

  function copyCell() {
    if (selRow < 0) return
    copyText(editText(cellValue(selRow, visibleColumns[selCol])))
    notify("Copied")
  }

  function copyRowJson() {
    if (selRow < 0) return
    const out = {}
    for (const c of visibleColumns) out[columns[c].name] = cellValue(selRow, c)
    copyText(JSON.stringify(out))
    notify("Copied row as JSON")
  }

  function copyInsert() {
    if (selRow < 0 || !source) return
    const names = visibleColumns.map(function(c) { return columns[c].name })
    const vals = visibleColumns.map(function(c) { const v = cellValue(selRow, c); return v === null ? "NULL" : typeof v === "number" ? String(v) : "'" + editText(v).replace(/'/g, "''") + "'" })
    copyText("INSERT INTO " + source.table + " (" + names.join(", ") + ") VALUES (" + vals.join(", ") + ");")
    notify("Copied row as INSERT")
  }

  function copyRow() {
    if (selRow < 0) return
    copyText(visibleColumns.map(function(c) { return editText(cellValue(selRow, c)) }).join("\t"))
    notify("Copied row")
  }
}
