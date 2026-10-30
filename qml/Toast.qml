import QtQuick
import qs.Commons
import qs.Commons as Commons

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
  color: Commons.Color.popups.background
  border.color: Commons.Color.popups.border
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
    color: Commons.Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
}
