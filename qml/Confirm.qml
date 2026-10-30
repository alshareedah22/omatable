import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// A question with an optional block of SQL to read before saying yes.
Popup {
  id: dlg

  property string title: ""
  property string text: ""
  property string detail: ""
  property string confirmText: "OK"
  property bool danger: false
  property bool busy: false
  property string error: ""
  property var onYes: null
  property var onNo: null
  property bool answered: false

  // opts: { title, text, detail, confirm, danger }; yes(dialog) runs on confirm
  // and closes the dialog itself (dlg.done()) or reports dlg.fail(message).
  // no() runs when the dialog closes without a yes.
  function ask(opts, yes, no) {
    title = opts.title || ""
    text = opts.text || ""
    detail = opts.detail || ""
    confirmText = opts.confirm || "OK"
    danger = !!opts.danger
    busy = false
    error = ""
    onYes = yes
    onNo = no || null
    answered = false
    open()
  }
  function done() { busy = false; answered = true; close() }
  onClosed: if (!answered && onNo) { const f = onNo; onNo = null; f() }
  function fail(message) { busy = false; error = message }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 80 : 600, detail ? 860 : 460)
  height: detail ? Math.min(parent ? parent.height - 80 : 500, 520) : implicitHeight
  padding: 16
  modal: true
  focus: true
  closePolicy: busy ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
  background: Rectangle { color: Commons.Color.popups.background; border.color: dlg.danger ? Commons.Color.urgent : Commons.Color.popups.border; border.width: 1 }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10
    Text {
      textFormat: Text.PlainText
      text: dlg.title
      color: dlg.danger ? Commons.Color.urgent : Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.text !== ""
      text: dlg.text
      wrapMode: Text.Wrap
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    ScrollView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: dlg.detail !== ""
      TextArea {
        readOnly: true
        selectByMouse: true
        text: dlg.detail
        wrapMode: TextEdit.Wrap
        color: Commons.Color.foreground
        font.family: "monospace"
        font.pixelSize: Style.font.body
        background: Rectangle { color: Qt.lighter(Commons.Color.background, 1.1) }
      }
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.error !== ""
      text: dlg.error
      wrapMode: Text.Wrap
      color: Commons.Color.urgent
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout {
      Layout.fillWidth: true
      Item { Layout.fillWidth: true }
      Ui.Button { text: "Cancel"; enabled: !dlg.busy; onClicked: dlg.close() }
      Ui.Button {
        bordered: true
        foreground: dlg.danger ? Commons.Color.urgent : Commons.Color.accent
        text: dlg.busy ? "Working…" : dlg.confirmText
        enabled: !dlg.busy
        onClicked: {
          dlg.busy = true
          dlg.error = ""
          if (dlg.onYes) dlg.onYes(dlg); else dlg.done()
        }
      }
    }
  }
}
