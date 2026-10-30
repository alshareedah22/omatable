import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// One OmaTablePlus window: its own helper process (tablectl) and its own connection tabs.
// The app (app/shell.qml) makes one per window; closing the window ends its helper.
FloatingWindow {
  id: window

  // where tablectl and the icon live (the app's runtime folder links them)
  property string baseDir: ""
  // connection ids to open as soon as the helper is ready (restore, launcher, OmaDBngin)
  property var startConnections: []
  readonly property string ctl: baseDir + "/tablectl"
  readonly property var openConnectionIds: {
    const ids = []
    for (let i = 0; i < sessionModel.count; i++) { const info = infos[sessionModel.get(i).sid]; if (info && info.id) ids.push(info.id) }
    return ids
  }
  signal finished()
  signal newWindowRequested(string connectionId)
  signal quitRequested()

  // for the menu bar
  readonly property int connectionCount: sessionModel.count
  readonly property var currentBrowser: active >= 0 && browsers.count > active && browsers.itemAt(active) ? browsers.itemAt(active).item : null
  function closeConnectionAt(i) { if (i >= 0) browsers.closeAt(i) }
  function cycleConnection(step) {
    if (sessionModel.count < 2) return
    active = (Math.max(0, active) + step + sessionModel.count) % sessionModel.count
  }
  function showShortcuts() { shortcutsPopup.open() }
  function showAbout() { aboutPopup.open() }

  readonly property string version: helperProc.version
  property var infos: ({})
  property int active: -1          // index in sessionModel; -1 shows the connection list
  readonly property var session: active >= 0 && active < sessionModel.count ? infos[sessionModel.get(active).sid] || null : null
  property string connecting: ""
  property var pendingConnects: []
  property int sessionRevision: 0   // bumps when the open connections change (session restore)

  ListModel { id: sessionModel }

  function indexOfConn(id) {
    for (let i = 0; i < sessionModel.count; i++) if (infos[sessionModel.get(i).sid].id === id) return i
    return -1
  }

  function connectTo(conn) {
    if (connecting) { pendingConnects = pendingConnects.concat([conn.id]); return }
    const open = indexOfConn(conn.id)
    if (open >= 0) { active = open; return }
    connecting = conn.name || conn.id
    helperProc.request("session.open", { id: conn.id, readonly: !!conn.readonly }, function(r, e) {
      connecting = ""
      if (e) welcome.toast = (conn.name || conn.id) + ": " + e.message
      else {
        const copy = Object.assign({}, infos)
        copy[r.session] = r
        infos = copy
        sessionModel.append({ sid: r.session })
        active = sessionModel.count - 1
        sessionRevision++
      }
      connectNextPending()
    })
  }

  function openConnection(id) {
    if (!id) return
    pendingConnects = pendingConnects.concat([id])
    connectNextPending()
  }

  function connectNextPending() {
    if (connecting || helperProc.status !== "ready" || pendingConnects.length === 0) return
    const id = pendingConnects[0]
    pendingConnects = pendingConnects.slice(1)
    connectTo({ id: id, name: String(id).replace(/^omadb:/, "") })
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
    sessionRevision++
  }

  function disconnectAll() {
    sessionModel.clear()
    infos = ({})
    active = -1
  }

  Component.onCompleted: {
    pendingConnects = startConnections.slice()
    helperProc.start()
  }

  onVisibleChanged: if (!visible) { helperProc.stop(); window.finished() }

  Helper {
    id: helperProc
    program: window.ctl
    confirmer: function(err, yes, no) {
      safeConfirm.ask({ title: "Production · " + (window.session ? window.session.name : ""), text: err.message,
                        detail: err.detail || "", confirm: "Run on production", danger: true },
                      function(dlg) { dlg.done(); yes() }, no)
    }
    onStatusChanged: { if (status !== "ready") window.disconnectAll(); else window.connectNextPending() }
  }

  title: active >= 0 && session ? session.name + " — OmaTablePlus" : "OmaTablePlus"
    color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 1)
    implicitWidth: 1100
    implicitHeight: 700
    minimumSize: Qt.size(760, 480)


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
          source: "file://" + window.baseDir + "/icon.svg"
          width: Math.round(Style.font.body * 3)
          height: width
          sourceSize: Qt.size(width * 2, height * 2)
        }
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: "OmaTablePlus"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body * 2
        }
      }
      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: helperProc.fatalText !== "" ? helperProc.fatalText
          : helperProc.status === "installing" ? helperProc.progressText
          : helperProc.status === "stopped" ? "Stopped" : "Starting…"
        color: helperProc.fatalText !== "" ? Commons.Color.urgent : Commons.Color.muted
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
      y: menuBar.height
      width: parent.width
      height: visible ? Math.round(Style.font.body * 2.2) : 0
      color: Qt.darker(Commons.Color.background, 1.12)
      Row {
        height: parent.height
        Repeater {
          model: sessionModel
          delegate: Rectangle {
            id: ctab
            required property int index
            required property string sid
            readonly property var info: window.infos[sid] || {}
            readonly property bool current: index === window.active
            width: Math.min(220, ctabText.implicitWidth + ctabClose.implicitWidth + 30)
            height: connStrip.height
            color: current ? Commons.Color.background : "transparent"
            Rectangle { width: parent.width; height: 2; color: ctab.info.color || Commons.Color.accent; visible: ctab.current }
            Rectangle { x: 8; anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: ctab.info.color || Commons.Color.accent }
            Text {
              id: ctabText
              textFormat: Text.PlainText
              x: 22
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, 160)
              elide: Text.ElideRight
              text: (ctab.info.name || "") + (ctab.info.tag === "production" ? "  ·  PROD" : "")
              color: ctab.current ? Commons.Color.foreground : Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: ctab.current
            }
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onClicked: function(mouse) { if (mouse.button === Qt.MiddleButton) browsers.closeAt(ctab.index); else window.active = ctab.index }
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
          selected: window.active === -1
          tooltipText: "Open another connection (Ctrl+Shift+N)"
          onClicked: window.active = -1
        }
      }
    }

    Item {
      id: content
      anchors.top: connStrip.visible ? connStrip.bottom : menuBar.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom

      Welcome {
        id: welcome
        anchors.fill: parent
        visible: helperProc.status === "ready" && window.active === -1
        helper: helperProc
        onConnectRequested: function(conn) { window.connectTo(conn) }
      }

      Repeater {
        id: browsers
        model: sessionModel
        // closing asks first when a browser has unsaved changes
        function closeAt(i) {
          const b = browsers.itemAt(i)
          const sid = sessionModel.get(i).sid
          if (b && b.item && typeof b.item.whenClean === "function") { window.active = i; b.item.whenClean(function() { window.disconnect(sid) }) }
          else window.disconnect(sid)
        }
        delegate: Loader {
          id: tabLoader
          required property int index
          required property string sid
          // fixed at open: the browser keeps its own copy as it switches databases
          readonly property var info: window.infos[sid] || null
          readonly property string engine: info ? info.engine : ""
          anchors.fill: parent
          visible: index === window.active && helperProc.status === "ready"
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
      visible: window.connecting !== ""
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
      MouseArea { anchors.fill: parent }
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: "Connecting to " + window.connecting + "…"
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body * 1.2
      }
    }

    Shortcut { sequence: "Ctrl+Shift+N"; enabled: window.visible && sessionModel.count > 0; onActivated: window.active = -1 }
    Shortcut { sequence: "Ctrl+PgDown"; enabled: window.visible && sessionModel.count > 1; onActivated: window.active = (window.active + 1) % sessionModel.count }
    Shortcut { sequence: "Ctrl+PgUp"; enabled: window.visible && sessionModel.count > 1; onActivated: window.active = (Math.max(0, window.active) - 1 + sessionModel.count) % sessionModel.count }
    Shortcut { sequence: "Ctrl+Alt+N"; onActivated: window.newWindowRequested("") }
    Shortcut { sequence: "Ctrl+Shift+W"; onActivated: window.visible = false }
    Shortcut { sequence: "Ctrl+Q"; onActivated: window.quitRequested() }

    AppMenuBar {
      id: menuBar
      win: window
      width: parent.width
      visible: helperProc.status === "ready"
      height: visible ? implicitHeight : 0
    }

    InfoPopup {
      id: shortcutsPopup
      title: "Keyboard shortcuts"
      rows: [
        ["Connections", "Ctrl+Shift+N"], ["Next / previous connection", "Ctrl+PgDown / Ctrl+PgUp"],
        ["New window", "Ctrl+Alt+N"], ["Close window", "Ctrl+Shift+W"], ["Quit", "Ctrl+Q"],
        ["New query", "Ctrl+T"], ["Close tab", "Ctrl+W"], ["Next / previous tab", "Ctrl+Tab / Ctrl+Shift+Tab"],
        ["Run statement / all", "Ctrl+Enter / Ctrl+Shift+Enter"], ["Cancel query", "Ctrl+."], ["Explain", "Ctrl+E"],
        ["History", "Ctrl+H"], ["Format SQL", "Ctrl+Shift+F"], ["Save query or changes", "Ctrl+S"],
        ["Insert row", "Ctrl+I"], ["Reload", "Ctrl+R / F5"], ["Filter", "Ctrl+F"], ["Discard changes", "Ctrl+Shift+Delete"],
        ["Console (Redis, MongoDB)", "Ctrl+`"], ["Open OmaTablePlus from anywhere", "SUPER+ALT+T"]
      ]
    }
    InfoPopup {
      id: aboutPopup
      title: "OmaTablePlus " + window.version
      rows: [["A TablePlus-style database client for Omarchy", ""], ["By BlackCode · MIT license", ""],
             ["PostgreSQL, MySQL, MariaDB, SQLite, Redis, Valkey, MongoDB", ""]]
    }

    Confirm { id: safeConfirm }
}
