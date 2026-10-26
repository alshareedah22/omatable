import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// Export a table (with its current filters and sort) or one query's rows to
// CSV, JSON or SQL INSERTs.
Popup {
  id: dlg

  property var helper: null
  property string sid: ""
  property string folder: ""
  property var target: ({})
  property string baseName: "export"
  property string format: "csv"
  property bool pathEdited: false
  property bool busy: false
  property string error: ""
  property bool confirmReplace: false
  signal notify(string text)

  function show(t, name) {
    target = t
    baseName = name || "export"
    pathEdited = false
    error = ""
    confirmReplace = false
    busy = false
    pathField.setText(folder + "/" + baseName + "." + format)
    tableField.setText(baseName)
    open()
  }

  function run(overwrite) {
    busy = true
    error = ""
    const params = { session: sid, target: target, format: format, path: pathField.text, overwrite: overwrite }
    if (format === "sql") params.table_name = tableField.text || baseName
    helper.request("export.run", params, function(r, e) {
      busy = false
      if (e) {
        if (e.code === "exists") { confirmReplace = true; error = e.message + ". Replace it?" }
        else error = e.message
        return
      }
      close()
      notify("Exported " + r.rows.toLocaleString(Qt.locale(), "f", 0) + (r.rows === 1 ? " row" : " rows") + " to " + r.path)
    })
  }

  onFormatChanged: if (!pathEdited) pathField.setText(folder + "/" + baseName + "." + format)

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 80 : 600, 560)
  padding: 16
  modal: true
  focus: true
  closePolicy: busy ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10
    Text {
      textFormat: Text.PlainText
      text: dlg.target.sql !== undefined ? "Export query results" : "Export " + dlg.baseName
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.target.sql === undefined && dlg.target.filters !== undefined && dlg.target.filters.length > 0
      text: "Only rows matching the current filters are exported."
      color: Color.muted
      wrapMode: Text.Wrap
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout {
      spacing: 6
      Repeater {
        model: [{ key: "csv", label: "CSV" }, { key: "json", label: "JSON" }, { key: "sql", label: "SQL INSERTs" }]
        delegate: Ui.Button {
          required property var modelData
          bordered: dlg.format === modelData.key
          text: modelData.label
          onClicked: dlg.format = modelData.key
        }
      }
    }
    Field {
      id: pathField
      Layout.fillWidth: true
      label: "File"
      onDirtyChanged: if (dirty) { dlg.pathEdited = true; dlg.confirmReplace = false; dlg.error = "" }
      onTextChanged: if (dirty) dlg.confirmReplace = false
    }
    Field {
      id: tableField
      Layout.fillWidth: true
      visible: dlg.format === "sql"
      label: "Table name in the INSERTs"
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.error !== ""
      text: dlg.error
      wrapMode: Text.Wrap
      color: dlg.confirmReplace ? Color.foreground : Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout {
      Layout.fillWidth: true
      Item { Layout.fillWidth: true }
      Ui.Button { text: "Cancel"; enabled: !dlg.busy; onClicked: dlg.close() }
      Ui.Button {
        bordered: true
        foreground: dlg.confirmReplace ? Color.urgent : Color.accent
        text: dlg.busy ? "Exporting…" : dlg.confirmReplace ? "Replace" : "Export"
        enabled: !dlg.busy && pathField.text.trim() !== ""
        onClicked: dlg.run(dlg.confirmReplace)
      }
    }
  }
}
