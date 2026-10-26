import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// "Working…" over the window while a long job runs, with a Cancel button.
Popup {
  id: dlg

  property string text: ""
  property real startedAt: 0
  property real elapsed: 0
  property bool cancelling: false
  property var onCancel: null

  function start(message, cancel) {
    text = message
    onCancel = cancel || null
    cancelling = false
    startedAt = Date.now()
    elapsed = 0
    open()
  }
  function finish() { close() }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 80 : 420, 440)
  padding: 18
  modal: true
  closePolicy: Popup.NoAutoClose
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  Timer { interval: 200; repeat: true; running: dlg.opened; onTriggered: dlg.elapsed = (Date.now() - dlg.startedAt) / 1000 }

  ColumnLayout {
    width: parent.width
    spacing: 12
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: dlg.text
      wrapMode: Text.Wrap
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    RowLayout {
      Layout.fillWidth: true
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: (dlg.cancelling ? "Stopping… " : "") + dlg.elapsed.toFixed(0) + " s"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button {
        visible: dlg.onCancel !== null
        enabled: !dlg.cancelling
        bordered: true
        foreground: Color.urgent
        text: "Cancel"
        onClicked: { dlg.cancelling = true; dlg.onCancel() }
      }
    }
  }
}
