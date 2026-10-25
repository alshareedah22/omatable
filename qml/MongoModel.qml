import QtQuick
import Quickshell
import qs.Commons
import "Values.js" as Values

// A page of MongoDB documents behind the DataGrid interface. Cells are not
// edited in place: Enter, double-click or the menu open the whole document
// in the JSON editor, and sorting asks the server.
Item {
  id: m

  property var result: null       // mongo.find / mongo.aggregate reply
  property var columns: []
  property var rows: []
  property var visibleColumns: []
  property var colWidths: []
  property var sort: []           // [{ column, desc }]
  readonly property bool readOnly: false
  readonly property bool editable: true
  property bool loading: false
  property string error: ""
  readonly property int offset: result ? result.skip : 0
  property int revision: 0
  readonly property int rowCount: rows.length
  property int selRow: -1
  property int selCol: 0
  readonly property string emptyText: "No documents"
  readonly property var menuItems: [
    { label: "Edit document", act: "edit" }, { label: "Duplicate document", act: "duplicate" },
    { label: "Copy value", act: "copy" }, { label: "Copy document as JSON", act: "copydoc" },
    { label: "Copy _id", act: "copyid" }, { label: "Insert document", act: "insert" },
    { label: "Delete document…", act: "delete" }]

  signal notify(string text)
  signal editRequested(int row)
  signal duplicateRequested(int row)
  signal insertRequested()
  signal deleteRequested(int row)
  signal sortRequested(var sort)

  onResultChanged: {
    columns = result ? result.columns.map(function(n) { return { name: n, type: "", pk: n === "_id", nullable: true, default: null } }) : []
    rows = result ? result.rows : []
    selRow = rows.length ? Math.min(Math.max(selRow, 0), rows.length - 1) : -1
    selCol = Math.min(selCol, Math.max(0, columns.length - 1))
    layoutColumns()
    revision++
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

  function display(v) { return v === null || v === undefined ? "—" : Values.display(v) }
  function editText(v) { return Values.editText(v) }
  function cellValue(r, c) { return rows[r] ? rows[r][c] : null }
  function isEdited(r, c) { return false }
  function rowState(r) { return "" }
  function canEdit(r) { if (r >= 0) editRequested(r); return false }
  function setCell(r, c, value) {}
  function toggleDelete(r) { if (r >= 0) deleteRequested(r) }
  function addRow() { insertRequested() }
  function select(r, vi) { selRow = r; selCol = vi }

  function toggleSort(name, add) {
    const desc = sort.length && sort[0].column === name && !sort[0].desc
    sort = [{ column: name, desc: desc }]
    sortRequested(sort)
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

  function copyRow() { copyRowJson() }
  function copyRowJson() {
    if (selRow < 0) return
    copyText(result.docs[selRow])
    notify("Copied the document")
  }

  function menuAction(act) {
    if (selRow < 0) return
    if (act === "duplicate") duplicateRequested(selRow)
    else if (act === "copydoc") copyRowJson()
    else if (act === "copyid") {
      const id = result.ids[selRow]
      if (id === null) { notify("This document has no _id"); return }
      copyText(cellValue(selRow, 0) !== null && typeof cellValue(selRow, 0) !== "object" ? String(cellValue(selRow, 0)) : id)
      notify("Copied _id")
    }
  }
}
