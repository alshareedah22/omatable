import QtQuick
import Quickshell
import qs.Commons
import "Values.js" as Values

// One query result behind the DataGrid interface: read-only, sorted in memory.
Item {
  id: m

  property var result: null
  property var columns: []
  property var rows: []
  property var visibleColumns: []
  property var colWidths: []
  property var sort: []
  readonly property bool readOnly: true
  readonly property bool editable: false
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
  function cellValue(r, c) { return rows[r] ? rows[r][c] : null }
  function isEdited(r, c) { return false }
  function rowState(r) { return "" }
  function canEdit(r) { notify("Query results are read-only; open the table to edit rows"); return false }
  function setCell(r, c, value) {}
  function toggleDelete(r) { canEdit(r) }
  function addRow() { canEdit(-1) }
  function select(r, vi) { selRow = r; selCol = vi }

  function toggleSort(name, add) {
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

  function copyRow() {
    if (selRow < 0) return
    copyText(visibleColumns.map(function(c) { return editText(cellValue(selRow, c)) }).join("\t"))
    notify("Copied row")
  }
}
