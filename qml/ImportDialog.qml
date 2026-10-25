import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// Import a CSV file into a table: pick the file, map each CSV column to a
// table column (or skip it), then insert every row in one transaction.
Popup {
  id: dlg

  property var helper: null
  property string sid: ""
  property string folder: ""
  property string schema: ""
  property string table: ""
  property var tableColumns: []
  property var preview: null
  property var mapping: []
  property bool header: true
  property bool emptyNull: true
  property bool busy: false
  property string error: ""
  signal notify(string text)
  signal imported(string schema, string table)

  function show(s, t) {
    schema = s
    table = t
    preview = null
    mapping = []
    error = ""
    busy = false
    pathField.setText(folder + "/" + t + ".csv")
    helper.request("struct.get", { session: sid, schema: s, table: t }, function(r, e) {
      tableColumns = e ? [] : r.columns.map(function(c) { return c.name })
    })
    open()
  }

  function load() {
    error = ""
    helper.request("import.preview", { path: pathField.text, delimiter: delimField.text || null }, function(r, e) {
      if (e) { error = e.message; preview = null; return }
      preview = r
      delimField.setText(r.delimiter === "\t" ? "\\t" : r.delimiter)
      const lower = tableColumns.map(function(c) { return c.toLowerCase() })
      mapping = r.header.map(function(h) {
        const i = lower.indexOf(String(h).trim().toLowerCase())
        return i >= 0 && header ? tableColumns[i] : ""
      })
    })
  }

  function run() {
    busy = true
    error = ""
    const delim = delimField.text === "\\t" ? "\t" : delimField.text || ","
    helper.request("import.run", { session: sid, schema: schema, table: table, path: pathField.text, mapping: mapping,
                                   delimiter: delim, header: header, empty_null: emptyNull }, function(r, e) {
      busy = false
      if (e) { error = e.message; return }
      close()
      notify("Imported " + r.inserted.toLocaleString(Qt.locale(), "f", 0) + (r.inserted === 1 ? " row" : " rows") + " into " + table)
      imported(schema, table)
    })
  }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 60 : 700, 720)
  height: Math.min(parent ? parent.height - 60 : 600, preview ? 640 : implicitHeight)
  padding: 16
  modal: true
  focus: true
  closePolicy: busy ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10
    Text {
      text: "Import CSV into " + dlg.table
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Field { id: pathField; Layout.fillWidth: true; label: "CSV file" }
      Field { id: delimField; Layout.preferredWidth: 80; label: "Delimiter"; placeholder: "auto" }
      Ui.Button { Layout.alignment: Qt.AlignBottom; bordered: true; text: "Read file"; onClicked: dlg.load() }
    }
    RowLayout {
      visible: dlg.preview !== null
      spacing: 8
      Ui.Button { bordered: true; text: dlg.header ? "First row is the header" : "No header row"; onClicked: { dlg.header = !dlg.header; dlg.load() } }
      Ui.Button { bordered: true; text: dlg.emptyNull ? "Empty → NULL" : "Empty → ''"; onClicked: dlg.emptyNull = !dlg.emptyNull }
      Text {
        text: dlg.preview ? (dlg.preview.count + (dlg.header ? 0 : 1)).toLocaleString(Qt.locale(), "f", 0) + " rows" : ""
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
    Text {
      visible: dlg.preview !== null
      text: "Map each CSV column to a table column"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    ListView {
      id: mapList
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: dlg.preview !== null
      clip: true
      spacing: 4
      model: dlg.preview ? dlg.preview.header.length : 0
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      delegate: RowLayout {
        id: mapRow
        required property int index
        width: mapList.width - 12
        spacing: 10
        Text {
          Layout.preferredWidth: 180
          text: dlg.header ? dlg.preview.header[mapRow.index] : "column " + (mapRow.index + 1)
          elide: Text.ElideRight
          color: Color.foreground
          font.family: "monospace"
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          Layout.preferredWidth: 160
          text: {
            const first = dlg.header ? dlg.preview.rows[0] : dlg.preview.header
            return first && first[mapRow.index] !== undefined ? "e.g. " + first[mapRow.index] : ""
          }
          elide: Text.ElideRight
          color: Color.muted
          font.family: "monospace"
          font.pixelSize: Style.font.bodySmall
        }
        Text { text: "→"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body }
        Ui.Dropdown {
          Layout.fillWidth: true
          showLabel: false
          options: [{ value: "", label: "skip" }].concat(dlg.tableColumns)
          value: dlg.mapping[mapRow.index] || ""
          onChanged: function(v) { const m = dlg.mapping.slice(); m[mapRow.index] = v; dlg.mapping = m }
        }
      }
    }
    Text {
      Layout.fillWidth: true
      visible: dlg.error !== ""
      text: dlg.error
      wrapMode: Text.Wrap
      color: Color.urgent
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: "All rows go in one transaction: one bad row and nothing is imported."
        color: Color.muted
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button { text: "Cancel"; enabled: !dlg.busy; onClicked: dlg.close() }
      Ui.Button {
        bordered: true
        foreground: Color.accent
        text: dlg.busy ? "Importing…" : "Import"
        enabled: !dlg.busy && dlg.preview !== null && dlg.mapping.some(function(m) { return m })
        onClicked: dlg.run()
      }
    }
  }
}
