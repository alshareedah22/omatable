import QtQuick
import qs.Commons

// A short message near the bottom of the window; expired() asks the owner
// to clear it.
Rectangle {
  id: toast

  property string message: ""
  signal expired()

  visible: message !== ""
  anchors.horizontalCenter: parent.horizontalCenter
  anchors.bottom: parent.bottom
  anchors.bottomMargin: 48
  width: Math.min(toastText.implicitWidth + 32, parent.width - 40)
  height: toastText.implicitHeight + 16
  radius: 6
  z: 50
  color: Color.popups.background
  border.color: Color.popups.border
  onMessageChanged: if (message) timer.restart()

  Timer { id: timer; interval: 4000; onTriggered: toast.expired() }
  Text {
    id: toastText
    textFormat: Text.PlainText
    anchors.centerIn: parent
    width: parent.width - 32
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    text: toast.message
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
}
