import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import "qml"

// The OmaTable window. The shell loads this as a panel; summon/hide call
// open()/close(), and closing the window ourselves tells the shell.
Item {
  id: root

  readonly property string pluginId: "blackcode.omatable"
  readonly property string ctl: decodeURIComponent(String(Qt.resolvedUrl("tablectl")).replace(/^file:\/\//, ""))
  readonly property bool opened: window.visible
  property bool closingFromHost: false
  property var shell: null

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    helper.start()
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else window.visible = false
  }

  Helper {
    id: helper
    program: root.ctl
  }

  FloatingWindow {
    id: window
    title: "OmaTable"
    color: Color.background
    implicitWidth: 1100
    implicitHeight: 700
    minimumSize: Qt.size(760, 480)

    onVisibleChanged: {
      if (!visible) helper.stop()
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    // Splash: shown until the helper is ready (first run installs drivers).
    Column {
      anchors.centerIn: parent
      spacing: 12
      visible: helper.status !== "ready"

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "  OmaTable"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body * 2
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: helper.fatalText !== "" ? helper.fatalText
          : helper.status === "installing" ? helper.progressText
          : helper.status === "stopped" ? "Stopped" : "Starting…"
        color: helper.fatalText !== "" ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        width: Math.min(implicitWidth, window.width - 80)
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
      }
      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: helper.status === "stopped"
        text: "Retry"
        onClicked: helper.start()
      }
    }
  }
}
