import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// The server's databases: create one, open one, or drop one.
Popup {
  id: dlg

  property var helper: null
  property string sid: ""
  property string engine: ""
  property var databases: []
  property string current: ""
  property bool busy: false
  property string error: ""
  signal changed(var databases, string database)
  signal openRequested(string database)
  signal notify(string text)

  readonly property bool postgres: engine === "postgresql"
  readonly property var system: postgres ? ["postgres"] : ["information_schema", "performance_schema", "mysql", "sys"]

  function show(list, db) {
    databases = list
    current = db
    nameField.setText("")
    error = ""
    busy = false
    open()
    nameField.focusInput()
  }

  function apply(r) {
    databases = r.databases
    current = r.database
    changed(r.databases, r.database)
  }

  function create() {
    const name = nameField.text.trim()
    if (busy || !name) return
    busy = true
    error = ""
    helper.request("db.create", { session: sid, name: name }, function(r, e) {
      busy = false
      if (e) { if (e.code !== "cancelled") error = e.message; return }
      nameField.setText("")
      apply(r)
      notify("Created the database " + name)
    })
  }

  function drop(name) {
    confirm.ask({ title: "Drop the database " + name + "?",
                  text: "This deletes every table and row in " + name + ". It cannot be undone.",
                  confirm: "Drop database", danger: true }, function(c) {
      helper.request("db.drop", { session: sid, name: name, confirmed: true }, function(r, e) {
        if (e) { c.fail(e.message); return }
        c.done()
        apply(r)
        notify("Dropped the database " + name)
      })
    })
  }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 60 : 520, 540)
  height: Math.min(parent ? parent.height - 60 : 560, 580)
  padding: 16
  modal: true
  focus: true
  closePolicy: busy ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
  background: Rectangle { color: Commons.Color.popups.background; border.color: Commons.Color.popups.border; border.width: 1 }

  ColumnLayout {
    anchors.fill: parent
    spacing: 10

    Text {
      textFormat: Text.PlainText
      text: "Databases"
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Field {
        id: nameField
        Layout.fillWidth: true
        label: "New database"
        placeholder: "name"
        Keys.onReturnPressed: dlg.create()
        Keys.onEnterPressed: dlg.create()
      }
      Ui.Button {
        Layout.alignment: Qt.AlignBottom
        bordered: true
        foreground: Commons.Color.accent
        text: dlg.busy ? "Creating…" : "Create"
        enabled: !dlg.busy && nameField.text.trim() !== ""
        onClicked: dlg.create()
      }
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.error !== ""
      text: dlg.error
      wrapMode: Text.Wrap
      color: Commons.Color.urgent
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }
    ListView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      model: dlg.databases
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      delegate: Rectangle {
        id: row
        required property string modelData
        readonly property bool isCurrent: modelData === dlg.current
        width: ListView.view.width
        height: Math.round(Style.font.body * 2.3)
        radius: 4
        color: hover.hovered ? Qt.lighter(Commons.Color.background, 1.25) : "transparent"
        HoverHandler { id: hover }
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 8
          anchors.rightMargin: 4
          spacing: 6
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: "  " + row.modelData + (row.isCurrent ? "   (open)" : "")
            color: dlg.system.indexOf(row.modelData) >= 0 ? Commons.Color.muted : Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: row.isCurrent
          }
          Ui.Button {
            visible: !row.isCurrent
            text: "Open"
            onClicked: { dlg.close(); dlg.openRequested(row.modelData) }
          }
          Ui.Button {
            text: "Drop…"
            foreground: Commons.Color.urgent
            visible: !(dlg.postgres && row.isCurrent)   // PostgreSQL cannot drop the database it is connected to
            tooltipText: "Drop this database"
            onClicked: dlg.drop(row.modelData)
          }
        }
      }
    }
    RowLayout {
      Layout.fillWidth: true
      Item { Layout.fillWidth: true }
      Ui.Button { text: "Close"; enabled: !dlg.busy; onClicked: dlg.close() }
    }
  }

  Confirm { id: confirm }
}
