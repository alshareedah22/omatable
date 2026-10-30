//@ pragma AppId omatableplus
//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import "qml"

// OmaTablePlus as its own app: run by the `omatableplus` launcher from a runtime folder that
// links this file, ../qml, tablectl, the icon, and Omarchy's Commons and Ui (for the theme).
// One process holds every window; closing the last window ends the app.
ShellRoot {
  id: app

  // the runtime folder (this file's folder): tablectl and icon.svg are linked next to it
  readonly property string baseDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string sessionPath: Quickshell.env("HOME") + "/.local/state/omatableplus/session.json"

  // one entry per window: {key, connections}; the windows report what they have open
  ListModel { id: windows }
  property int nextKey: 1
  property bool restored: false

  function newWindow(connections) {
    windows.append({ key: nextKey++, connections: JSON.stringify(connections || []) })
  }

  function windowAt(i) { return instances.objectAt(i) }

  function focusWindow(win) {
    if (!win) return
    Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "title:^" + win.title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$"])
  }

  // Opens a connection in the window that has it, else in the most recent window.
  function open(connectionId) {
    for (let i = 0; i < windows.count; i++) {
      const w = windowAt(i)
      if (w && connectionId && w.indexOfConn(connectionId) >= 0) { w.active = w.indexOfConn(connectionId); focusWindow(w); return }
    }
    if (windows.count === 0) { newWindow(connectionId ? [connectionId] : []); return }
    const last = windowAt(windows.count - 1)
    if (connectionId) last.openConnection(connectionId)
    focusWindow(last)
  }

  // Session: which connections each window has open, written as they change.
  function saveSession() {
    if (!restored) return
    const list = []
    for (let i = 0; i < windows.count; i++) { const w = windowAt(i); if (w) list.push(w.openConnectionIds) }
    sessionFile.setText(JSON.stringify({ windows: list }) + "\n")
  }

  FileView {
    id: sessionFile
    path: app.sessionPath
    blockLoading: true
    atomicWrites: true
    printErrors: false
  }

  Instantiator {
    id: instances
    model: windows
    delegate: AppWindow {
      required property int index
      required property string connections
      baseDir: app.baseDir
      startConnections: JSON.parse(connections)
      visible: true
      onSessionRevisionChanged: app.saveSession()
      onNewWindowRequested: function(id) { app.newWindow(id ? [id] : []) }
      onQuitRequested: Qt.quit()
      onFinished: Qt.callLater(function() {
        // the last window closing ends the app; its session stays for the next start
        if (windows.count === 1) Qt.quit()
        else { windows.remove(index); app.saveSession() }
      })
    }
  }

  Component.onCompleted: {
    // Restore the last session, then whatever the launcher asked for.
    let restore = []
    try {
      const s = JSON.parse(sessionFile.text())
      // windows that had connections open; an empty one is not worth reopening
      if (s && Array.isArray(s.windows)) restore = s.windows.filter(function(w) { return Array.isArray(w) && w.length > 0 })
    } catch (e) {}
    if (restore.length === 0) restore = [[]]
    restore.forEach(function(ids) { app.newWindow(ids) })
    app.restored = true
    const ask = Quickshell.env("OMATABLEPLUS_OPEN") || ""
    if (ask === "new-window") app.newWindow([])
    else if (ask !== "") app.open(ask)
  }

  // The launcher talks to a running app through here (a second launch never starts a second app).
  IpcHandler {
    target: "omatableplus"
    function ping(): string { return "pong" }
    function focus(): void { app.open("") }
    function open(connectionId: string): void { app.open(connectionId) }
    function newWindow(): void { app.newWindow([]) }
    function openInNewWindow(connectionId: string): void { app.newWindow(connectionId ? [connectionId] : []) }
  }
}
