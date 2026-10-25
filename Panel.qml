import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui as Ui
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
  property var session: null       // session.open result while a connection is open
  property string connecting: ""

  function connectTo(conn) {
    if (connecting) return
    connecting = conn.name
    helperProc.request("session.open", { id: conn.id }, function(r, e) {
      connecting = ""
      if (e) { welcome.toast = conn.name + ": " + e.message; return }
      session = r
    })
  }

  function disconnect() {
    if (session) helperProc.request("session.close", { session: session.session }, null)
    session = null
  }

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    helperProc.start()
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
    id: helperProc
    program: root.ctl
    confirmer: function(err, yes, no) {
      safeConfirm.ask({ title: "Production · " + (root.session ? root.session.name : ""), text: err.message,
                        detail: err.detail || "", confirm: "Run on production", danger: true },
                      function(dlg) { dlg.done(); yes() }, no)
    }
    onStatusChanged: if (status !== "ready") root.session = null
  }

  FloatingWindow {
    id: window
    title: "OmaTable"
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
    implicitWidth: 1100
    implicitHeight: 700
    minimumSize: Qt.size(760, 480)

    onVisibleChanged: {
      if (!visible) helperProc.stop()
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    // Splash: shown until the helper is ready (first run installs drivers).
    Column {
      anchors.centerIn: parent
      spacing: 12
      visible: helperProc.status !== "ready"

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 12
        Image {
          anchors.verticalCenter: parent.verticalCenter
          source: Qt.resolvedUrl("icon.svg")
          width: Math.round(Style.font.body * 3)
          height: width
          sourceSize: Qt.size(width * 2, height * 2)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "OmaTable"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body * 2
        }
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: helperProc.fatalText !== "" ? helperProc.fatalText
          : helperProc.status === "installing" ? helperProc.progressText
          : helperProc.status === "stopped" ? "Stopped" : "Starting…"
        color: helperProc.fatalText !== "" ? Color.urgent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        width: Math.min(implicitWidth, window.width - 80)
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
      }
      Ui.Button {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: helperProc.status === "stopped"
        bordered: true
        text: "Retry"
        onClicked: helperProc.start()
      }
    }

    Welcome {
      id: welcome
      anchors.fill: parent
      visible: helperProc.status === "ready" && !root.session
      helper: helperProc
      onConnectRequested: function(conn) { root.connectTo(conn) }
    }

    Rectangle {
      visible: root.connecting !== ""
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
      MouseArea { anchors.fill: parent }
      Text {
        anchors.centerIn: parent
        text: "Connecting to " + root.connecting + "…"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body * 1.2
      }
    }

    Loader {
      anchors.fill: parent
      active: root.session !== null
      visible: active && helperProc.status === "ready"
      readonly property string engine: root.session ? root.session.engine : ""
      sourceComponent: !engine ? null : engine === "redis" || engine === "valkey" ? redisBrowser : engine === "mongodb" ? mongoBrowser : sqlWorkspace
    }
    Confirm { id: safeConfirm }
    Component {
      id: sqlWorkspace
      Workspace {
        helper: helperProc
        info: root.session
        onCloseRequested: whenClean(function() { root.disconnect() })
      }
    }
    Component {
      id: redisBrowser
      RedisBrowser {
        helper: helperProc
        info: root.session
        onCloseRequested: whenClean(function() { root.disconnect() })
      }
    }
    Component {
      id: mongoBrowser
      MongoBrowser {
        helper: helperProc
        info: root.session
        onCloseRequested: root.disconnect()
      }
    }
  }
}
