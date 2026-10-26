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
  // Open connections, one tab each: sessionModel keeps the order (and the
  // browsers alive), infos maps a session id to its session.open result.
  property var infos: ({})
  property int active: -1          // index in sessionModel; -1 shows the connection list
  readonly property var session: active >= 0 && active < sessionModel.count ? infos[sessionModel.get(active).sid] || null : null
  property string connecting: ""

  ListModel { id: sessionModel }

  function indexOfConn(id) {
    for (let i = 0; i < sessionModel.count; i++) if (infos[sessionModel.get(i).sid].id === id) return i
    return -1
  }

  function connectTo(conn) {
    if (connecting) return
    const open = indexOfConn(conn.id)
    if (open >= 0) { active = open; return }
    connecting = conn.name
    helperProc.request("session.open", { id: conn.id, readonly: !!conn.readonly }, function(r, e) {
      connecting = ""
      if (e) { welcome.toast = conn.name + ": " + e.message; return }
      const copy = Object.assign({}, infos)
      copy[r.session] = r
      infos = copy
      sessionModel.append({ sid: r.session })
      active = sessionModel.count - 1
    })
  }

  function disconnect(sid) {
    let i = 0
    for (; i < sessionModel.count; i++) if (sessionModel.get(i).sid === sid) break
    if (i === sessionModel.count) return
    helperProc.request("session.close", { session: sid }, null)
    sessionModel.remove(i)
    const copy = Object.assign({}, infos)
    delete copy[sid]
    infos = copy
    if (active > i || active >= sessionModel.count) active = Math.min(active - (active > i ? 1 : 0), sessionModel.count - 1)
  }

  function disconnectAll() {
    sessionModel.clear()
    infos = ({})
    active = -1
  }

  // summon with {"connect": "<connection id>"} (OmaDBngin's Open in OmaTable sends "omadb:<name>")
  property string pendingConnect: ""
  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    try {
      const p = payloadJson ? JSON.parse(payloadJson) : {}
      if (p && typeof p.connect === "string" && p.connect) pendingConnect = p.connect
    } catch (e) {}
    helperProc.start()
    connectPending()
  }
  function connectPending() {
    if (!pendingConnect || helperProc.status !== "ready") return
    const id = pendingConnect
    pendingConnect = ""
    connectTo({ id: id, name: id.replace(/^omadb:/, "") })
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
    onStatusChanged: { if (status !== "ready") root.disconnectAll(); else root.connectPending() }
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

    // ---- connection tabs ----
    Rectangle {
      id: connStrip
      visible: sessionModel.count > 0 && helperProc.status === "ready"
      width: parent.width
      height: visible ? Math.round(Style.font.body * 2.2) : 0
      color: Qt.darker(Color.background, 1.12)
      Row {
        height: parent.height
        Repeater {
          model: sessionModel
          delegate: Rectangle {
            id: ctab
            required property int index
            required property string sid
            readonly property var info: root.infos[sid] || {}
            readonly property bool current: index === root.active
            width: Math.min(220, ctabText.implicitWidth + ctabClose.implicitWidth + 30)
            height: connStrip.height
            color: current ? Color.background : "transparent"
            Rectangle { width: parent.width; height: 2; color: ctab.info.color || Color.accent; visible: ctab.current }
            Rectangle { x: 8; anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: ctab.info.color || Color.accent }
            Text {
              id: ctabText
              x: 22
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, 160)
              elide: Text.ElideRight
              text: (ctab.info.name || "") + (ctab.info.tag === "production" ? "  ·  PROD" : "")
              color: ctab.current ? Color.foreground : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: ctab.current
            }
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onClicked: function(mouse) { if (mouse.button === Qt.MiddleButton) browsers.closeAt(ctab.index); else root.active = ctab.index }
            }
            Ui.Button {
              id: ctabClose
              anchors.right: parent.right
              anchors.rightMargin: 2
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              fontSize: Style.font.bodySmall
              tooltipText: "Close this connection"
              onClicked: browsers.closeAt(ctab.index)
            }
          }
        }
        Ui.Button {
          height: connStrip.height
          text: "+"
          selected: root.active === -1
          tooltipText: "Open another connection (Ctrl+Shift+N)"
          onClicked: root.active = -1
        }
      }
    }

    Item {
      id: content
      anchors.top: connStrip.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom

      Welcome {
        id: welcome
        anchors.fill: parent
        visible: helperProc.status === "ready" && root.active === -1
        helper: helperProc
        onConnectRequested: function(conn) { root.connectTo(conn) }
      }

      Repeater {
        id: browsers
        model: sessionModel
        // closing asks first when a browser has unsaved changes
        function closeAt(i) {
          const b = browsers.itemAt(i)
          const sid = sessionModel.get(i).sid
          if (b && b.item && typeof b.item.whenClean === "function") { root.active = i; b.item.whenClean(function() { root.disconnect(sid) }) }
          else root.disconnect(sid)
        }
        delegate: Loader {
          id: tabLoader
          required property int index
          required property string sid
          // fixed at open: the browser keeps its own copy as it switches databases
          readonly property var info: root.infos[sid] || null
          readonly property string engine: info ? info.engine : ""
          anchors.fill: parent
          visible: index === root.active && helperProc.status === "ready"
          sourceComponent: !engine ? null : engine === "redis" || engine === "valkey" ? redisBrowser : engine === "mongodb" ? mongoBrowser : sqlWorkspace
          Component {
            id: sqlWorkspace
            Workspace { helper: helperProc; info: tabLoader.info; onCloseRequested: browsers.closeAt(tabLoader.index) }
          }
          Component {
            id: redisBrowser
            RedisBrowser { helper: helperProc; info: tabLoader.info; onCloseRequested: browsers.closeAt(tabLoader.index) }
          }
          Component {
            id: mongoBrowser
            MongoBrowser { helper: helperProc; info: tabLoader.info; onCloseRequested: browsers.closeAt(tabLoader.index) }
          }
        }
      }
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

    Shortcut { sequence: "Ctrl+Shift+N"; enabled: window.visible && sessionModel.count > 0; onActivated: root.active = -1 }
    Shortcut { sequence: "Ctrl+PgDown"; enabled: window.visible && sessionModel.count > 1; onActivated: root.active = (root.active + 1) % sessionModel.count }
    Shortcut { sequence: "Ctrl+PgUp"; enabled: window.visible && sessionModel.count > 1; onActivated: root.active = (Math.max(0, root.active) - 1 + sessionModel.count) % sessionModel.count }
    Confirm { id: safeConfirm }
  }
}
