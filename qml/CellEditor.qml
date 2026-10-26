import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui
import "Values.js" as Values

// One cell in a large editor: long text, JSON (formatted when it parses), or
// the value set to NULL or to the column's DEFAULT.
Popup {
  id: dlg

  property var tab: null
  property int row: -1
  property int col: -1
  property var column: null
  property string error: ""
  readonly property bool sqlite: tab && tab.engine === "sqlite"
  readonly property bool isNew: tab && row >= tab.rows.length
  readonly property bool jsonType: column && /json/i.test(column.type || "")

  function edit(r, c) {
    row = r
    col = c
    column = tab.columns[c]
    error = ""
    const v = tab.cellValue(r, c)
    let text = Values.editText(v)
    if (v !== null && typeof v === "object" && v.$t === undefined) text = JSON.stringify(v, null, 2)
    else if (jsonType && text) { try { text = JSON.stringify(JSON.parse(text), null, 2) } catch (e) {} }
    area.text = text
    nullNote.visible = v === null
    open()
    area.forceActiveFocus()
    area.cursorPosition = 0
  }

  function apply() {
    let text = area.text
    // JSON columns are saved compact, as the server stores them anyway
    if (jsonType && text.trim()) {
      try { text = JSON.stringify(JSON.parse(text)) } catch (e) { error = "Not valid JSON: " + e.message; return }
    }
    tab.setCell(row, col, text)
    close()
  }
  function setNull() { tab.setCell(row, col, null); close() }
  function setDefault() { tab.setCell(row, col, { $t: "default" }); close() }
  function formatJson() {
    try { area.text = JSON.stringify(JSON.parse(area.text), null, 2); error = "" } catch (e) { error = "Not valid JSON: " + e.message }
  }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 60 : 700, 820)
  height: Math.min(parent ? parent.height - 60 : 560, 640)
  padding: 16
  modal: true
  focus: true
  closePolicy: Popup.CloseOnEscape
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  ColumnLayout {
    anchors.fill: parent
    spacing: 8
    RowLayout {
      Layout.fillWidth: true
      Text {
        textFormat: Text.PlainText
        text: dlg.column ? dlg.column.name : ""
        color: Color.foreground
        font.family: "monospace"
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: !dlg.column ? "" : (dlg.column.type || "") + (dlg.column.nullable === false ? "  NOT NULL" : "")
          + (dlg.column.default !== null && dlg.column.default !== undefined ? "  DEFAULT " + dlg.column.default : "")
        color: Color.muted
        font.family: "monospace"
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        id: nullNote
        textFormat: Text.PlainText
        text: "currently NULL"
        color: Color.muted
        font.italic: true
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
    ScrollView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      TextArea {
        id: area
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        color: Color.foreground
        font.family: "monospace"
        font.pixelSize: Style.font.body
        background: Rectangle { color: Qt.lighter(Color.background, 1.1); border.color: area.activeFocus ? Color.accent : Qt.lighter(Color.background, 1.5); radius: 4 }
        onTextChanged: nullNote.visible = false
        Keys.onPressed: function(event) {
          const ctrl = event.modifiers & Qt.ControlModifier
          if (ctrl && (event.key === Qt.Key_S || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { dlg.apply(); event.accepted = true }
        }
      }
    }
    Text {
      textFormat: Text.PlainText
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
      spacing: 6
      Ui.Button { bordered: true; text: "Set NULL"; enabled: !dlg.column || dlg.column.nullable !== false; onClicked: dlg.setNull() }
      Ui.Button {
        bordered: true
        text: "Set DEFAULT"
        visible: !dlg.sqlite || dlg.isNew
        tooltipText: "The column's default; the server fills it in when the change is saved"
        onClicked: dlg.setDefault()
      }
      Ui.Button { bordered: true; text: "Format JSON"; onClicked: dlg.formatJson() }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: "Ctrl+S applies · Esc cancels · saved with the other changes"
        color: Color.muted
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button { text: "Cancel"; onClicked: dlg.close() }
      Ui.Button { bordered: true; foreground: Color.accent; text: "Apply"; onClicked: dlg.apply() }
    }
  }
}
