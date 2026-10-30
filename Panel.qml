import QtQuick
import Quickshell

// OmaTablePlus 2.0 runs as its own app (app/shell.qml). This panel only forwards: summoning it
// (OmaDBngin's "Open in OmaTablePlus" sends {"connect": "omadb:<name>"}) opens the app on that
// connection, then hands the panel straight back to the shell.
Item {
  id: root

  readonly property string pluginId: "blackcode.omatableplus"
  readonly property string launcher: decodeURIComponent(String(Qt.resolvedUrl("app/omatableplus")).replace(/^file:\/\//, ""))
  property var shell: null

  function open(payloadJson) {
    let connect = ""
    try {
      const p = payloadJson ? JSON.parse(payloadJson) : {}
      if (p && typeof p.connect === "string") connect = p.connect
    } catch (e) {}
    Quickshell.execDetached(connect ? [root.launcher, "open", connect] : [root.launcher])
    Qt.callLater(function() { if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId) })
  }

  function close() {}
}
