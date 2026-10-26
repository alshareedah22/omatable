import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// Edit one document (or a list of them, when inserting) as Extended JSON.
// mongosh syntax works too: unquoted keys, ObjectId("…"), ISODate("…").
Popup {
  id: dlg

  property string title: ""
  property string hint: ""
  property string confirmText: "Save"
  property bool busy: false
  property string error: ""
  property var onSave: null       // function(text, dlg); call dlg.done() or dlg.fail(message)

  function edit(opts, save) {
    title = opts.title || ""
    hint = opts.hint || ""
    confirmText = opts.confirm || "Save"
    area.text = opts.text || ""
    busy = false
    error = ""
    onSave = save
    open()
  }
  function done() { busy = false; close() }
  function fail(message) { busy = false; error = message }
  function save() {
    if (busy) return
    busy = true
    error = ""
    onSave(area.text, dlg)
  }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 60 : 700, 820)
  height: Math.min(parent ? parent.height - 60 : 600, 760)
  padding: 16
  modal: true
  focus: true
  closePolicy: busy ? Popup.NoAutoClose : Popup.CloseOnEscape
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }
  onOpened: { area.forceActiveFocus(); area.cursorPosition = 0 }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10
    Text {
      textFormat: Text.PlainText
      text: dlg.title
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.hint !== ""
      text: dlg.hint
      wrapMode: Text.Wrap
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
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
        tabStopDistance: Style.font.body * 1.4
        background: Rectangle { color: Qt.lighter(Color.background, 1.1); border.color: area.activeFocus ? Color.accent : Qt.lighter(Color.background, 1.5); radius: 4 }
        Keys.onPressed: function(event) {
          const ctrl = event.modifiers & Qt.ControlModifier
          if (ctrl && (event.key === Qt.Key_S || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { dlg.save(); event.accepted = true }
          else if (event.key === Qt.Key_Tab) { area.insert(area.cursorPosition, "  "); event.accepted = true }
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
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: "Ctrl+S saves · Esc cancels"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button { text: "Cancel"; enabled: !dlg.busy; onClicked: dlg.close() }
      Ui.Button { bordered: true; foreground: Color.accent; text: dlg.busy ? "Saving…" : dlg.confirmText; enabled: !dlg.busy; onClicked: dlg.save() }
    }
  }
}
