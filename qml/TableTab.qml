import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Values.js" as Values

// One table: filter bar, grid and status bar. Edits are staged here
// (edited cells, inserted rows, deleted rows) until Ctrl+S commits them in
// one transaction; a failed commit keeps them staged.
Item {
  id: tab

  property var helper: null
  property string sid: ""
  property string schema: ""
  property string table: ""
  property string engine: ""
  property string view: "data"        // data | structure
  property bool active: false

  // data from table.rows
  property var columns: []
  property var rows: []
  property var key: []
  property bool editable: false
  property int offset: 0
  property int limit: 300
  property int total: -1
  property int ms: 0
  property var sort: []
  property var filters: []
  property string match: "and"
  property bool loading: false
  property string error: ""
  property var visibleColumns: []
  property var colWidths: []

  // staged edits
  property var edits: ({})       // row -> { columnIndex: value }
  property var deleted: ({})     // row -> true
  property var inserted: []      // [{ columnIndex: value }]
  property int revision: 0
  readonly property int rowCount: { revision; return rows.length + inserted.length }
  readonly property int changeCount: { revision; return Object.keys(edits).length + Object.keys(deleted).length + inserted.length }
  readonly property bool dirty: changeCount > 0 || (structureLoader.item !== null && structureLoader.item.dirty)

  property int selRow: -1
  property int selCol: 0
  property string statements: ""

  signal notify(string text)
  signal exportRequested(var target, string name)
  signal sqlRequested(string sql, string title)

  // ---- loading ----
  function reload(resetOffset) {
    if (resetOffset) offset = 0
    loading = true
    error = ""
    helper.request("table.rows", { session: sid, schema: schema, table: table, offset: offset, limit: limit,
                                   sort: sort, filters: filters, match: match }, function(r, e) {
      loading = false
      if (e) { error = e.message; return }
      const sameShape = columns.length === r.columns.length && columns.every(function(c, i) { return c.name === r.columns[i].name })
      columns = r.columns
      rows = r.rows
      key = r.key
      editable = r.editable
      ms = r.ms
      if (!sameShape) layoutColumns()
      clearStaged()
      if (selRow >= rowCount) selRow = rowCount - 1
    })
    helper.request("table.count", { session: sid, schema: schema, table: table, filters: filters, match: match },
                   function(r, e) { total = e ? -1 : r.count })
  }

  function layoutColumns() {
    const vis = [], widths = []
    const charW = Style.font.body * 0.62
    for (let i = 0; i < columns.length; i++) {
      if (columns[i].hidden) continue
      vis.push(i)
      let w = (columns[i].name.length + (columns[i].pk ? 3 : 0)) * charW + 40
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

  // ---- values ----
  function display(v) { return Values.display(v) }
  function editText(v) { return Values.editText(v) }

  function cellValue(r, c) {
    if (r >= rows.length) {
      const ins = inserted[r - rows.length]
      return ins && (c in ins) ? ins[c] : null
    }
    const e = edits[r]
    if (e && (c in e)) return e[c]
    return rows[r] ? rows[r][c] : null
  }

  function isEdited(r, c) {
    if (r >= rows.length) { const ins = inserted[r - rows.length]; return !!ins && (c in ins) }
    return !!edits[r] && (c in edits[r])
  }

  function rowState(r) {
    if (r >= rows.length) return "inserted"
    if (deleted[r]) return "deleted"
    return edits[r] ? "edited" : ""
  }

  function canEdit(r) {
    if (r >= rows.length) return true
    if (!editable) { notify(key.length ? "This row cannot be edited" : "No primary key: rows of " + table + " are read-only"); return false }
    if (deleted[r]) { notify("Restore the row before editing it"); return false }
    return true
  }

  function setCell(r, c, value) {
    if (r < 0 || c < 0 || !canEdit(r)) return
    if (r >= rows.length) {
      inserted[r - rows.length][c] = value
    } else {
      const orig = rows[r][c]
      const same = value === null ? orig === null : (orig !== null && editText(orig) === value)
      const e = edits[r] || {}
      if (same) delete e[c]; else e[c] = value
      if (Object.keys(e).length) edits[r] = e; else delete edits[r]
    }
    revision++
  }

  function openEditor(r, c) { cellEditor.edit(r, c) }

  function select(r, vi) {
    selRow = r
    selCol = vi
  }

  function insertRow() {
    // Inserting needs no key, so even read-only (keyless) tables take new rows.
    inserted.push({})
    revision++
    select(rowCount - 1, 0)
  }

  function addRow() {
    insertRow()
    grid.forceActiveFocus()
    grid.ensureVisible(selRow, 0)
  }

  function toggleDelete(r) {
    if (r < 0) return
    if (r >= rows.length) {
      inserted.splice(r - rows.length, 1)
      revision++
      if (selRow >= rowCount) selRow = rowCount - 1
      return
    }
    if (!editable) { canEdit(r); return }
    if (deleted[r]) delete deleted[r]; else { deleted[r] = true; delete edits[r] }
    revision++
  }

  function clearStaged() {
    edits = ({})
    deleted = ({})
    inserted = []
    revision++
  }

  function changes() {
    const keyOf = function(r) {
      const k = {}
      for (const name of key) k[name] = rows[r][columns.findIndex(function(c) { return c.name === name })]
      return k
    }
    const named = function(obj) {
      const out = {}
      for (const c in obj) out[columns[c].name] = obj[c]
      return out
    }
    const out = { updates: [], deletes: [], inserts: [] }
    for (const r in deleted) out.deletes.push({ key: keyOf(r) })
    for (const r in edits) out.updates.push({ key: keyOf(r), values: named(edits[r]) })
    for (const ins of inserted) out.inserts.push({ values: named(ins) })
    return out
  }

  function commit() {
    if (!dirty || loading) return
    loading = true
    error = ""
    helper.request("table.commit", { session: sid, schema: schema, table: table, changes: changes() }, function(r, e) {
      loading = false
      if (e) { error = e.message; return }
      notify("Saved " + r.affected + (r.affected === 1 ? " row" : " rows"))
      reload(false)
    })
  }

  function discard() {
    clearStaged()
    error = ""
  }

  // Data edits and staged structure changes.
  function discardAll() {
    discard()
    if (structureLoader.item) structureLoader.item.clear()
  }

  function preview() {
    helper.request("table.preview", { session: sid, schema: schema, table: table, changes: changes() }, function(r, e) {
      if (e) { error = e.message; return }
      statements = r.statements.join("\n")
      previewPopup.open()
    })
  }

  function toggleSort(name, add) {
    if (dirty) { notify("Commit (Ctrl+S) or discard (Ctrl+Shift+Delete) your changes before sorting"); return }
    const i = sort.findIndex(function(s) { return s.column === name })
    let next = add ? sort.slice() : []
    if (i < 0) next.push({ column: name, desc: false })
    else if (!sort[i].desc) { const s = { column: name, desc: true }; if (add) next[i] = s; else next = [s] }
    else if (add) next.splice(i, 1)
    sort = next
    reload(true)
  }

  function sortMark(name) {
    const i = sort.findIndex(function(s) { return s.column === name })
    if (i < 0) return ""
    return (sort[i].desc ? "▼" : "▲") + (sort.length > 1 ? String(i + 1) : "")
  }

  function copyText(text) { clipboard.copy(text) }

  function rowObject(r) {
    const out = {}
    for (const c of visibleColumns) out[columns[c].name] = cellValue(r, c)
    return out
  }

  function copyRowJson() {
    if (selRow < 0) return
    copyText(JSON.stringify(rowObject(selRow)))
    notify("Copied row as JSON")
  }

  function copyInsert() {
    if (selRow < 0) return
    helper.request("table.preview", { session: sid, schema: schema, table: table,
                                      changes: { inserts: [{ values: rowObject(selRow) }] } }, function(r, e) {
      if (e) { notify(e.message); return }
      copyText(r.statements.join("\n"))
      notify("Copied row as INSERT")
    })
  }

  function exportTable() {
    exportRequested({ schema: schema, table: table, sort: sort, filters: filters, match: match }, table)
  }

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

  function page(delta) {
    if (dirty) { notify("Commit (Ctrl+S) or discard (Ctrl+Shift+Delete) your changes first"); return }
    offset = Math.max(0, offset + delta * limit)
    reload(false)
  }

  Component.onCompleted: reload(true)

  readonly property bool dataActive: active && view === "data"
  Shortcut { sequences: [StandardKey.Save]; enabled: tab.dataActive; onActivated: tab.commit() }
  Shortcut { sequence: "Ctrl+Shift+Delete"; enabled: tab.dataActive; onActivated: tab.discard() }
  Shortcut { sequence: "Ctrl+I"; enabled: tab.dataActive; onActivated: tab.addRow() }
  Shortcut { sequence: "Ctrl+R"; enabled: tab.dataActive; onActivated: { if (tab.changeCount) tab.notify("Commit or discard first"); else tab.reload(false) } }
  Shortcut { sequences: [StandardKey.Refresh]; enabled: tab.dataActive; onActivated: { if (!tab.changeCount) tab.reload(false) } }
  Shortcut { sequences: [StandardKey.Find]; enabled: tab.dataActive; onActivated: filterBar.addFilter() }

  function showView(v) {
    if (v === view) return
    if (v === "structure" && changeCount) { notify("Commit (Ctrl+S) or discard (Ctrl+Shift+Delete) your data changes first"); return }
    if (v === "data" && structureLoader.item && structureLoader.item.dirty) { notify("Apply or discard your structure changes first"); return }
    view = v
    if (v === "structure") {
      // a fresh view loads itself; an existing one may be stale
      if (structureLoader.item) structureLoader.item.reload()
      else structureLoader.active = true
    }
  }

  Loader {
    id: structureLoader
    anchors.fill: parent
    anchors.bottomMargin: switchBar.height
    active: false
    visible: tab.view === "structure"
    sourceComponent: Structure {
      helper: tab.helper
      sid: tab.sid
      schema: tab.schema
      table: tab.table
      engine: tab.engine
      active: tab.active && tab.view === "structure"
      onNotify: function(text) { tab.notify(text) }
      onApplied: tab.reload(true)
      onSqlRequested: function(sql, title) { tab.sqlRequested(sql, title) }
      Component.onCompleted: reload()
    }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.bottomMargin: switchBar.height
    spacing: 0
    visible: tab.view === "data"

    FilterBar {
      id: filterBar
      Layout.fillWidth: true
      columns: tab.visibleColumns.map(function(i) { return tab.columns[i].name })
      onApply: function(f, m) {
        if (tab.dirty) { tab.notify("Commit or discard your changes before filtering"); return }
        tab.filters = f
        tab.match = m
        tab.reload(true)
      }
    }

    CellEditor { id: cellEditor; tab: tab }
    DataGrid {
      id: grid
      Layout.fillWidth: true
      Layout.fillHeight: true
      tab: tab
      focus: true
    }

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      Layout.margins: 8
      visible: tab.error !== ""
      text: tab.error
      color: Commons.Color.urgent
      wrapMode: Text.Wrap
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    // ---- status bar ----
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: status.implicitHeight + 10
      color: Qt.lighter(Commons.Color.background, 1.08)
      RowLayout {
        id: status
        x: 8
        width: parent.width - 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Ui.Button { text: "‹"; tooltipText: "Previous page"; enabled: tab.offset > 0; onClicked: tab.page(-1) }
        Text {
          textFormat: Text.PlainText
          text: tab.loading ? "Loading…"
            : (tab.rows.length ? (tab.offset + 1) + "–" + (tab.offset + tab.rows.length) : "0")
              + (tab.total >= 0 ? " of " + tab.total.toLocaleString(Qt.locale(), "f", 0) : "") + " rows · " + tab.ms + " ms"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Ui.Button {
          text: "›"
          tooltipText: "Next page"
          enabled: tab.total < 0 ? tab.rows.length === tab.limit : tab.offset + tab.rows.length < tab.total
          onClicked: tab.page(1)
        }
        Ui.Button { text: "\uf021"; tooltipText: "Refresh (Ctrl+R)"; onClicked: { if (tab.dirty) tab.notify("Commit or discard first"); else tab.reload(false) } }
        Text {
          textFormat: Text.PlainText
          visible: !tab.editable && tab.columns.length > 0
          text: "read-only"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Item { Layout.fillWidth: true }
        Ui.Button { visible: !tab.dirty; bordered: true; text: "Export"; tooltipText: "Export these rows to CSV, JSON or SQL"; onClicked: tab.exportTable() }
        Ui.Button { bordered: true; text: "+ Row"; tooltipText: "Insert row (Ctrl+I)"; onClicked: tab.addRow() }
        Ui.Button { visible: tab.dirty; bordered: true; text: "Preview SQL"; onClicked: tab.preview() }
        Ui.Button { visible: tab.dirty; bordered: true; text: "Discard"; tooltipText: "Ctrl+Shift+Delete"; onClicked: tab.discard() }
        Ui.Button {
          visible: tab.dirty
          bordered: true
          foreground: Commons.Color.accent
          text: "Commit " + tab.changeCount + (tab.changeCount === 1 ? " change" : " changes")
          tooltipText: "Ctrl+S"
          enabled: !tab.loading
          onClicked: tab.commit()
        }
      }
    }
  }

  Rectangle {
    id: switchBar
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: switchRow.implicitHeight + 8
    color: Qt.lighter(Commons.Color.background, 1.12)
    Row {
      id: switchRow
      x: 8
      anchors.verticalCenter: parent.verticalCenter
      spacing: 4
      Ui.Button { bordered: tab.view === "data"; text: "Data"; fontSize: Style.font.bodySmall; onClicked: tab.showView("data") }
      Ui.Button { bordered: tab.view === "structure"; text: "Structure"; fontSize: Style.font.bodySmall; onClicked: tab.showView("structure") }
    }
  }

  Popup {
    id: previewPopup
    anchors.centerIn: parent
    width: Math.min(parent.width - 80, 900)
    height: Math.min(parent.height - 80, 500)
    padding: 16
    modal: true
    background: Rectangle { color: Commons.Color.popups.background; border.color: Commons.Color.popups.border; border.width: 1 }
    ColumnLayout {
      anchors.fill: parent
      spacing: 10
      Text { textFormat: Text.PlainText; text: "SQL to run on commit"; color: Commons.Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
      ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        TextArea {
          readOnly: true
          selectByMouse: true
          text: tab.statements
          wrapMode: TextEdit.Wrap
          color: Commons.Color.foreground
          font.family: "monospace"
          font.pixelSize: Style.font.body
          background: Rectangle { color: Qt.lighter(Commons.Color.background, 1.1) }
        }
      }
      RowLayout {
        Item { Layout.fillWidth: true }
        Ui.Button { bordered: true; text: "Copy"; onClicked: tab.copyText(tab.statements) }
        Ui.Button { bordered: true; text: "Commit"; onClicked: { previewPopup.close(); tab.commit() } }
        Ui.Button { text: "Close"; onClicked: previewPopup.close() }
      }
    }
  }

  Clipboard { id: clipboard }
}
