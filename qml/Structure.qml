import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui as Ui

// A table's columns, indexes, foreign keys and DDL. Changes are staged like
// grid edits; Ctrl+S shows the DDL and applies it after a yes.
Item {
  id: st

  property var helper: null
  property string sid: ""
  property string schema: ""
  property string table: ""
  property string engine: ""
  property bool active: false

  property var info: null
  property bool loading: false
  property string error: ""
  property string page: "columns"

  // staged changes
  property var colEdits: ({})     // column name -> { field: value }
  property var dropped: ({})      // column name -> true
  property var added: []          // [{ name, type, nullable, default, comment }]
  property var idxDropped: ({})
  property var idxAdded: []       // [{ name, columns, unique }]
  property var fkDropped: ({})
  property int revision: 0
  readonly property int changeCount: {
    revision
    return Object.keys(colEdits).length + Object.keys(dropped).length + added.length
      + Object.keys(idxDropped).length + idxAdded.length + Object.keys(fkDropped).length
  }
  readonly property bool dirty: changeCount > 0
  readonly property bool sqlite: engine === "sqlite"
  readonly property var columns: info ? info.columns : []
  readonly property int rowCount: { revision; return columns.length + added.length }

  signal notify(string text)
  signal applied()

  function reload() {
    loading = true
    error = ""
    helper.request("struct.get", { session: sid, schema: schema, table: table }, function(r, e) {
      loading = false
      if (e) { error = e.message; return }
      info = r
      clear()
    })
  }

  function clear() {
    colEdits = ({}); dropped = ({}); added = []
    idxDropped = ({}); idxAdded = []; fkDropped = ({})
    revision++
  }

  function original(c, field) { return field === "name" ? c.name : c[field] }

  function value(r, field) {
    if (r >= columns.length) return added[r - columns.length][field]
    const c = columns[r]
    const e = colEdits[c.name]
    return e && (field in e) ? e[field] : original(c, field)
  }

  function setValue(r, field, v) {
    if (field === "default" && v === "") v = null
    if (r >= columns.length) {
      added[r - columns.length][field] = v
    } else {
      const c = columns[r]
      const e = colEdits[c.name] || {}
      const orig = original(c, field)
      if (v === orig || (field === "comment" && (v || "") === (orig || ""))) delete e[field]; else e[field] = v
      if (Object.keys(e).length) colEdits[c.name] = e; else delete colEdits[c.name]
    }
    revision++
  }

  function rowState(r) {
    if (r >= columns.length) return "added"
    if (dropped[columns[r].name]) return "dropped"
    return colEdits[columns[r].name] ? "edited" : ""
  }

  function toggleDrop(r) {
    if (r >= columns.length) { added.splice(r - columns.length, 1); revision++; return }
    const name = columns[r].name
    if (dropped[name]) delete dropped[name]; else { dropped[name] = true; delete colEdits[name] }
    revision++
  }

  function addColumn() {
    added.push({ name: "", type: sqlite ? "TEXT" : engine === "postgresql" ? "text" : "varchar(255)",
                 nullable: true, default: null, comment: "" })
    revision++
    page = "columns"
    focusNew.restart()
  }

  function addIndex(name, cols, unique) {
    const list = cols.split(",").map(function(x) { return x.trim() }).filter(function(x) { return x })
    if (!name.trim() || !list.length) { notify("An index needs a name and at least one column"); return false }
    idxAdded.push({ name: name.trim(), columns: list, unique: unique })
    revision++
    return true
  }

  function toggle(map, key) {
    if (map[key]) delete map[key]; else map[key] = true
    revision++
  }

  function changes() {
    const cols = []
    for (const name in dropped) cols.push({ op: "drop", name: name })
    for (const name in colEdits) {
      const e = colEdits[name], item = { op: "alter", name: name }
      for (const f in e) item[f === "name" ? "new_name" : f] = e[f]
      cols.push(item)
    }
    for (const a of added) cols.push(Object.assign({ op: "add" }, a))
    const idx = []
    for (const name in idxDropped) idx.push({ op: "drop", name: name })
    for (const a of idxAdded) idx.push(Object.assign({ op: "add" }, a))
    const fks = []
    for (const name in fkDropped) fks.push({ op: "drop", name: name })
    return { columns: cols, indexes: idx, foreign_keys: fks }
  }

  function review() {
    if (!dirty || loading) return
    helper.request("struct.preview", { session: sid, schema: schema, table: table, changes: changes() }, function(r, e) {
      if (e) { error = e.message; return }
      error = ""
      confirm.ask({ title: "Apply " + r.statements.length + (r.statements.length === 1 ? " statement" : " statements") + " to " + table,
                    text: engine === "mysql" || engine === "mariadb"
                      ? "MySQL applies each statement on its own; if one fails, the ones before it stay applied." : "",
                    detail: r.statements.join("\n"), confirm: "Apply" }, function(dlg) {
        helper.request("struct.apply", { session: sid, schema: schema, table: table, changes: changes() }, function(r2, e2) {
          if (e2) { dlg.fail(e2.message); reload(); return }
          dlg.done()
          notify("Structure of " + table + " updated")
          reload()
          applied()
        })
      })
    })
  }

  Timer { id: focusNew; interval: 50; onTriggered: { colList.positionViewAtEnd(); const it = colList.itemAtIndex(st.rowCount - 1); if (it) it.focusName() } }

  Shortcut { sequences: [StandardKey.Save]; enabled: st.active && st.visible; onActivated: st.review() }
  Shortcut { sequence: "Ctrl+Shift+Delete"; enabled: st.active && st.visible; onActivated: st.clear() }

  Confirm { id: confirm }

  component Cell: Ui.TextField {
    font.family: "monospace"
    font.pixelSize: Style.font.bodySmall
    verticalPadding: 2
  }
  component HeadText: Text {
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  readonly property int wName: Math.max(110, width * 0.2)
  readonly property int wType: Math.max(100, width * 0.17)
  readonly property int wNull: 84
  readonly property int wDefault: Math.max(100, width * 0.18)

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    // ---- toolbar ----
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: bar.implicitHeight + 10
      color: Qt.lighter(Color.background, 1.08)
      clip: true
      RowLayout {
        id: bar
        x: 8
        width: parent.width - 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        Repeater {
          model: [{ key: "columns", label: "Columns" }, { key: "indexes", label: "Indexes" },
                  { key: "fks", label: "Foreign keys" }, { key: "ddl", label: "DDL" }]
          delegate: Ui.Button {
            required property var modelData
            bordered: st.page === modelData.key
            fontSize: Style.font.bodySmall
            text: modelData.label
            onClicked: st.page = modelData.key
          }
        }
        Item { Layout.fillWidth: true }
        Ui.Button { visible: st.page === "columns"; bordered: true; text: "+ Column"; onClicked: st.addColumn() }
        Ui.Button { visible: st.dirty; bordered: true; text: "Discard"; tooltipText: "Ctrl+Shift+Delete"; onClicked: st.clear() }
        Ui.Button {
          visible: st.dirty
          bordered: true
          foreground: Color.accent
          text: "Review " + st.changeCount + (st.changeCount === 1 ? " change" : " changes")
          tooltipText: "Show the SQL and apply it (Ctrl+S)"
          onClicked: st.review()
        }
      }
    }

    Text {
      Layout.fillWidth: true
      Layout.margins: 8
      visible: st.error !== ""
      text: st.error
      color: Color.urgent
      wrapMode: Text.Wrap
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }

    StackLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      currentIndex: ["columns", "indexes", "fks", "ddl"].indexOf(st.page)

      // ---- columns ----
      ColumnLayout {
        spacing: 0
        RowLayout {
          Layout.fillWidth: true
          Layout.leftMargin: 34
          Layout.rightMargin: 8
          Layout.topMargin: 6
          spacing: 6
          HeadText { Layout.preferredWidth: st.wName; text: "Name" }
          HeadText { Layout.preferredWidth: st.wType; text: "Type" }
          HeadText { Layout.preferredWidth: st.wNull; text: "Null" }
          HeadText { Layout.preferredWidth: st.wDefault; text: "Default (SQL)" }
          HeadText { Layout.fillWidth: true; visible: !st.sqlite; text: "Comment" }
          Item { Layout.fillWidth: st.sqlite; implicitWidth: 30 }
        }
        ListView {
          id: colList
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          model: st.rowCount
          spacing: 2
          topMargin: 4
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          delegate: Rectangle {
            id: colRow
            required property int index
            readonly property string state_: { st.revision; return st.rowState(index) }
            readonly property bool existing: index < st.columns.length
            readonly property bool locked: state_ === "dropped"
            // SQLite can only rename an existing column
            readonly property bool renameOnly: st.sqlite && existing
            function focusName() { nameField.forceActiveFocus() }
            width: colList.width
            height: rowLay.implicitHeight + 6
            color: state_ === "dropped" ? Qt.rgba(0.85, 0.25, 0.25, 0.22)
              : state_ === "added" ? Qt.rgba(0.3, 0.75, 0.35, 0.18)
              : state_ === "edited" ? Qt.rgba(0.95, 0.75, 0.2, 0.18) : "transparent"
            RowLayout {
              id: rowLay
              x: 8
              width: parent.width - 16
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              Text {
                Layout.preferredWidth: 20
                text: colRow.existing && st.columns[colRow.index].pk ? "" : ""
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Cell {
                id: nameField
                Layout.preferredWidth: st.wName
                enabled: !colRow.locked
                font.strikeout: colRow.locked
                text: { st.revision; return st.value(colRow.index, "name") || "" }
                placeholderText: "name"
                onTextEdited: st.setValue(colRow.index, "name", text)
              }
              Cell {
                Layout.preferredWidth: st.wType
                enabled: !colRow.locked && !colRow.renameOnly
                text: { st.revision; return st.value(colRow.index, "type") || "" }
                placeholderText: "type"
                onTextEdited: st.setValue(colRow.index, "type", text)
              }
              Ui.Button {
                Layout.preferredWidth: st.wNull
                bordered: true
                enabled: !colRow.locked && !colRow.renameOnly
                fontSize: Style.font.bodySmall
                text: { st.revision; return st.value(colRow.index, "nullable") ? "NULL" : "NOT NULL" }
                onClicked: st.setValue(colRow.index, "nullable", !st.value(colRow.index, "nullable"))
              }
              Cell {
                Layout.preferredWidth: st.wDefault
                enabled: !colRow.locked && !colRow.renameOnly
                text: { st.revision; const v = st.value(colRow.index, "default"); return v === null || v === undefined ? "" : String(v) }
                placeholderText: "none"
                onTextEdited: st.setValue(colRow.index, "default", text)
              }
              Cell {
                Layout.fillWidth: true
                visible: !st.sqlite
                enabled: !colRow.locked
                text: { st.revision; return st.value(colRow.index, "comment") || "" }
                onTextEdited: st.setValue(colRow.index, "comment", text)
              }
              Item { Layout.fillWidth: st.sqlite; implicitWidth: 1 }
              Ui.Button {
                text: colRow.locked ? "↺" : "✕"
                tooltipText: colRow.locked ? "Keep this column" : colRow.existing ? "Drop this column" : "Remove"
                onClicked: st.toggleDrop(colRow.index)
              }
            }
          }
          Text {
            x: 16
            y: 12
            visible: st.loading
            text: "Loading…"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
        Text {
          Layout.fillWidth: true
          Layout.margins: 8
          visible: st.sqlite
          text: "SQLite can rename, add and drop columns. To change a type, NULL rule or default, recreate the table."
          color: Color.muted
          wrapMode: Text.Wrap
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      // ---- indexes ----
      ColumnLayout {
        spacing: 4
        ListView {
          id: idxList
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.topMargin: 6
          clip: true
          spacing: 2
          model: { st.revision; return (st.info ? st.info.indexes : []).concat(st.idxAdded.map(function(a) { return Object.assign({ added: true }, a) })) }
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          delegate: Rectangle {
            id: ixRow
            required property var modelData
            required property int index
            readonly property bool gone: { st.revision; return !!st.idxDropped[modelData.name] && !modelData.added }
            width: idxList.width
            height: ixLay.implicitHeight + 8
            color: gone ? Qt.rgba(0.85, 0.25, 0.25, 0.22) : modelData.added ? Qt.rgba(0.3, 0.75, 0.35, 0.18) : "transparent"
            RowLayout {
              id: ixLay
              x: 12
              width: parent.width - 20
              anchors.verticalCenter: parent.verticalCenter
              spacing: 10
              Text {
                Layout.preferredWidth: 220
                text: ixRow.modelData.name
                elide: Text.ElideRight
                color: Color.foreground
                font.strikeout: ixRow.gone
                font.family: "monospace"
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                Layout.fillWidth: true
                text: "(" + ixRow.modelData.columns.join(", ") + ")"
                  + (ixRow.modelData.primary ? "   PRIMARY KEY" : ixRow.modelData.unique ? "   UNIQUE" : "")
                elide: Text.ElideRight
                color: ixRow.modelData.primary ? Color.accent : Color.muted
                font.family: "monospace"
                font.pixelSize: Style.font.bodySmall
              }
              Ui.Button {
                visible: !ixRow.modelData.primary
                text: ixRow.gone ? "↺" : "✕"
                tooltipText: ixRow.gone ? "Keep this index" : ixRow.modelData.added ? "Remove" : "Drop this index"
                onClicked: {
                  if (ixRow.modelData.added) { st.idxAdded.splice(ixRow.index - st.info.indexes.length, 1); st.revision++ }
                  else st.toggle(st.idxDropped, ixRow.modelData.name)
                }
              }
            }
          }
        }
        RowLayout {
          Layout.fillWidth: true
          Layout.margins: 8
          spacing: 6
          Cell { id: ixName; Layout.preferredWidth: 200; placeholderText: "index name" }
          Cell { id: ixCols; Layout.fillWidth: true; placeholderText: "columns: " + st.columns.map(function(c) { return c.name }).slice(0, 4).join(", ") }
          Ui.Button { id: ixUnique; property bool on: false; bordered: true; text: on ? "UNIQUE" : "not unique"; onClicked: on = !on }
          Ui.Button {
            bordered: true
            text: "+ Index"
            onClicked: if (st.addIndex(ixName.text, ixCols.text, ixUnique.on)) { ixName.text = ""; ixCols.text = ""; ixUnique.on = false }
          }
        }
      }

      // ---- foreign keys ----
      ListView {
        id: fkList
        clip: true
        spacing: 2
        topMargin: 6
        model: st.info ? st.info.foreign_keys : []
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: Rectangle {
          id: fkRow
          required property var modelData
          readonly property bool gone: { st.revision; return !!st.fkDropped[modelData.name] }
          width: fkList.width
          height: fkLay.implicitHeight + 8
          color: gone ? Qt.rgba(0.85, 0.25, 0.25, 0.22) : "transparent"
          RowLayout {
            id: fkLay
            x: 12
            width: parent.width - 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Text {
              Layout.fillWidth: true
              text: fkRow.modelData.name + "   (" + fkRow.modelData.columns.join(", ") + ") → "
                + (fkRow.modelData.ref_schema && fkRow.modelData.ref_schema !== st.schema ? fkRow.modelData.ref_schema + "." : "")
                + fkRow.modelData.ref_table + " (" + fkRow.modelData.ref_columns.join(", ") + ")"
                + "   ON DELETE " + fkRow.modelData.on_delete + "   ON UPDATE " + fkRow.modelData.on_update
              elide: Text.ElideRight
              color: Color.foreground
              font.strikeout: fkRow.gone
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
            }
            Ui.Button {
              visible: !st.sqlite
              text: fkRow.gone ? "↺" : "✕"
              tooltipText: fkRow.gone ? "Keep this foreign key" : "Drop this foreign key"
              onClicked: st.toggle(st.fkDropped, fkRow.modelData.name)
            }
          }
        }
        Text {
          x: 16
          y: 12
          visible: fkList.count === 0
          text: "No foreign keys"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      // ---- DDL ----
      ColumnLayout {
        spacing: 6
        ScrollView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.margins: 8
          TextArea {
            readOnly: true
            selectByMouse: true
            text: st.info ? st.info.ddl : ""
            wrapMode: TextEdit.NoWrap
            color: Color.foreground
            font.family: "monospace"
            font.pixelSize: Style.font.body
            background: Rectangle { color: Qt.darker(Color.background, 1.15) }
          }
        }
        RowLayout {
          Layout.margins: 8
          Item { Layout.fillWidth: true }
          Ui.Button {
            bordered: true
            text: "Copy"
            onClicked: { Quickshell.execDetached(["wl-copy", "--", st.info ? st.info.ddl : ""]); st.notify("Copied the DDL") }
          }
        }
      }
    }
  }
}
