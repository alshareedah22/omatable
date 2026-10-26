import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// What is running on the server: one row per connection or operation, with
// Stop (cancel its query) and Kill (close its connection). Refreshes itself.
Popup {
  id: dlg

  property var helper: null
  property string sid: ""
  property string engine: ""
  property var items: []
  property string error: ""
  property bool live: true
  property bool hideIdle: true
  property var expanded: ({})
  signal notify(string message)

  readonly property bool mongo: engine === "mongodb"
  readonly property var shown: hideIdle ? items.filter(function(p) { return !/^(idle|Sleep)$/.test(p.state) }) : items

  function show() { expanded = ({}); error = ""; open(); refresh() }
  function refresh() {
    helper.request("server.processes", { session: sid }, function(r, e) {
      if (e) { error = e.message; return }
      error = ""
      items = r.processes
    })
  }
  function stop(p, hard) {
    const run = function(c) {
      helper.request("server.kill", { session: sid, id: p.id, hard: hard, confirmed: true }, function(r, e) {
        if (c) { if (e) { c.fail(e.message); return } c.done() }
        else if (e) { notify(e.message); return }
        notify((hard ? "Closed the connection of " : "Stopped the query of ") + p.id)
        refresh()
      })
    }
    if (!hard) { run(null); return }
    confirm.ask({ title: "Kill process " + p.id + "?", text: "Its connection closes; " + (p.user || "the client") + " has to reconnect, and an open transaction is rolled back.",
                  confirm: "Kill", danger: true }, run)
  }
  function secs(s) { return s < 60 ? s.toFixed(s < 10 ? 1 : 0) + " s" : s < 3600 ? Math.floor(s / 60) + " min" : (s / 3600).toFixed(1) + " h" }

  Timer { interval: 2000; repeat: true; running: dlg.opened && dlg.live; onTriggered: dlg.refresh() }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 40 : 900, 1000)
  height: Math.min(parent ? parent.height - 40 : 650, 760)
  padding: 16
  modal: true
  focus: true
  closePolicy: Popup.CloseOnEscape
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  component Head: Text { textFormat: Text.PlainText; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true; elide: Text.ElideRight }
  component Cell: Text { textFormat: Text.PlainText; color: Color.foreground; font.family: "monospace"; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }

  ColumnLayout {
    anchors.fill: parent
    spacing: 8
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Text {
        textFormat: Text.PlainText
        text: dlg.mongo ? "Running operations" : "Running queries"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: dlg.shown.length + " of " + dlg.items.length + (dlg.live ? " · refreshing every 2 s" : "")
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button { visible: !dlg.mongo; bordered: true; selected: dlg.hideIdle; text: "Hide idle"; onClicked: dlg.hideIdle = !dlg.hideIdle }
      Ui.Button { bordered: true; selected: !dlg.live; text: dlg.live ? "Pause" : "Resume"; onClicked: dlg.live = !dlg.live }
      Ui.Button { bordered: true; text: "Refresh"; onClicked: dlg.refresh() }
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.error !== ""
      text: dlg.error
      wrapMode: Text.Wrap
      color: Color.urgent
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Head { Layout.preferredWidth: 80; text: "id" }
      Head { Layout.preferredWidth: 90; text: "user" }
      Head { Layout.preferredWidth: 90; text: "database" }
      Head { Layout.preferredWidth: 80; text: "state" }
      Head { Layout.preferredWidth: 60; text: "time" }
      Head { Layout.fillWidth: true; text: dlg.mongo ? "command" : "query" }
      Item { Layout.preferredWidth: dlg.mongo ? 60 : 120 }
    }
    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: dlg.shown
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      delegate: Rectangle {
        id: row
        required property var modelData
        readonly property var p: modelData
        readonly property bool open_: !!dlg.expanded[p.id]
        width: list.width
        height: (open_ ? Math.max(lay.implicitHeight, full.implicitHeight + lay.implicitHeight + 6) : lay.implicitHeight) + 8
        color: hover.hovered ? Qt.lighter(Color.background, 1.15) : "transparent"
        HoverHandler { id: hover }
        TapHandler { onTapped: { const o = Object.assign({}, dlg.expanded); o[row.p.id] = !o[row.p.id]; dlg.expanded = o } }
        RowLayout {
          id: lay
          x: 0
          y: 4
          width: parent.width
          spacing: 8
          Cell { Layout.preferredWidth: 80; text: String(row.p.id) }
          Cell { Layout.preferredWidth: 90; text: row.p.user }
          Cell { Layout.preferredWidth: 90; text: row.p.database }
          Cell { Layout.preferredWidth: 80; text: row.p.state + (row.p.wait ? " · " + row.p.wait : ""); color: /active|Query|query|update|insert|remove|command/.test(row.p.state) ? Color.accent : Color.muted }
          Cell { Layout.preferredWidth: 60; text: dlg.secs(row.p.seconds); color: row.p.seconds > 10 && /active|Query/.test(row.p.state) ? Color.urgent : Color.foreground }
          Cell { Layout.fillWidth: true; text: row.p.query.replace(/\s+/g, " "); color: Color.muted }
          Ui.Button { text: "Stop"; tooltipText: "Cancel the running query; the connection stays"; onClicked: dlg.stop(row.p, false) }
          Ui.Button { visible: !dlg.mongo; text: "Kill"; foreground: Color.urgent; tooltipText: "Close the connection"; onClicked: dlg.stop(row.p, true) }
        }
        Text {
          id: full
          textFormat: Text.PlainText
          visible: row.open_
          x: 8
          y: lay.y + lay.implicitHeight + 4
          width: parent.width - 16
          wrapMode: Text.Wrap
          text: (row.p.client ? "client " + row.p.client + (row.p.app ? " · " + row.p.app : "") + "\n" : "") + row.p.query
          color: Color.foreground
          font.family: "monospace"
          font.pixelSize: Style.font.bodySmall
        }
      }
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: list.count === 0
        text: dlg.items.length ? "Only idle connections" : "Nothing else is running"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
    RowLayout {
      Layout.fillWidth: true
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: "Click a row for the whole query. Your own OmaTable connection is not listed."
        color: Color.muted
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button { text: "Close"; onClicked: dlg.close() }
    }
  }

  Confirm { id: confirm }
}
