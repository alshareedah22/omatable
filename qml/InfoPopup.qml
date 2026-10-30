import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// A small read-only list in a popup: a title, then rows of [text, hint]. Esc or OK closes it.
Popup {
  id: pop
  property string title: ""
  property var rows: []

  parent: Overlay.overlay
  anchors.centerIn: parent
  modal: true
  focus: true
  padding: Style.space(18)
  width: Math.min(Style.space(560), parent ? parent.width - Style.space(40) : Style.space(560))
  background: Rectangle {
    color: Commons.Color.popups.background
    border.color: Commons.Color.popups.border
    border.width: 1
  }

  Column {
    width: parent.width
    spacing: Style.space(6)
    Text {
      textFormat: Text.PlainText
      text: pop.title
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      bottomPadding: Style.space(6)
    }
    Repeater {
      model: pop.rows
      delegate: Item {
        required property var modelData
        width: parent.width
        height: Math.max(left.implicitHeight, right.implicitHeight)
        Text {
          textFormat: Text.PlainText
          id: left
          width: parent.width - right.implicitWidth - Style.space(12)
          wrapMode: Text.Wrap
          text: modelData[0]
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          textFormat: Text.PlainText
          id: right
          anchors.right: parent.right
          text: modelData[1]
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
    Ui.Button {
      anchors.right: parent.right
      bordered: true
      text: "OK"
      onClicked: pop.close()
    }
  }
}
