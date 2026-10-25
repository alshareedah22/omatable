import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// An open session: title strip, schema sidebar and one tab per table.
Item {
  id: ws

  property var helper: null
  property var info: null          // session.open result
  property var tree: []
  property bool treeLoading: false
  property int current: -1
  property string toast: ""
  signal closeRequested()

  readonly property bool dirty: {
    for (let i = 0; i < tabStack.count; i++) { const t = tabStack.itemAt(i); if (t && t.dirty) return true }
    return false
  }

  function loadTree() {
    treeLoading = true
    helper.request("schema.tree", { session: info.session }, function(r, e) {
      treeLoading = false
      if (e) { toast = e.message; return }
      tree = r.schemas
    })
  }

  function openTable(schema, table) {
    for (let i = 0; i < tabModel.count; i++) {
      const t = tabModel.get(i)
      if (t.schema === schema && t.table === table) { current = i; return }
    }
    tabModel.append({ schema: schema, table: table })
    current = tabModel.count - 1
  }

  function closeTab(i) {
    const t = tabStack.itemAt(i)
    if (t && t.dirty) {
      current = i
      toast = "Commit (Ctrl+S) or discard (Ctrl+Shift+Delete) the changes in " + tabModel.get(i).table + " first"
      return
    }
    tabModel.remove(i)
    current = Math.min(current >= i ? current - 1 : current, tabModel.count - 1)
    if (current < 0 && tabModel.count) current = 0
  }

  function switchDatabase(db) {
    if (dirty) { toast = "Commit or discard your changes before switching databases"; dbBox.value = info.database; return }
    helper.request("session.use", { session: info.session, database: db }, function(r, e) {
      if (e) { toast = e.message; dbBox.value = info.database; return }
      info = Object.assign({}, info, { database: r.database })
      tabModel.clear()
      current = -1
      loadTree()
    })
  }

  Component.onCompleted: loadTree()

  Shortcut { sequence: "Ctrl+W"; enabled: ws.visible && ws.current >= 0; onActivated: ws.closeTab(ws.current) }
  Shortcut { sequence: "Ctrl+Tab"; enabled: ws.visible && tabModel.count > 1; onActivated: ws.current = (ws.current + 1) % tabModel.count }
  Shortcut { sequence: "Ctrl+Shift+Tab"; enabled: ws.visible && tabModel.count > 1; onActivated: ws.current = (ws.current - 1 + tabModel.count) % tabModel.count }

  ListModel { id: tabModel }
  Timer { id: toastTimer; interval: 4000; onTriggered: ws.toast = "" }
  onToastChanged: if (toast) toastTimer.restart()

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    // ---- title strip ----
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: titleRow.implicitHeight + 12
      color: Qt.lighter(Color.background, 1.12)
      Rectangle { width: parent.width; height: 3; color: ws.info ? ws.info.color : "transparent" }
      RowLayout {
        id: titleRow
        x: 10
        width: parent.width - 20
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10
        Ui.Button { text: "‹ Connections"; tooltipText: "Close this connection"; onClicked: ws.closeRequested() }
        Text {
          text: ws.info ? ws.info.name : ""
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Rectangle {
          visible: ws.info && ws.info.tag === "production"
          implicitWidth: prodText.implicitWidth + 12
          implicitHeight: prodText.implicitHeight + 4
          radius: 3
          color: "#c94040"
          Text { id: prodText; anchors.centerIn: parent; text: "PRODUCTION"; color: "white"; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true }
        }
        Text {
          text: ws.info ? ws.info.version + (ws.info.ssh ? "  ·   SSH" : "") : ""
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Item { Layout.fillWidth: true }
        Text {
          visible: dbBox.visible
          text: "Database"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Ui.Dropdown {
          id: dbBox
          visible: ws.info && ws.info.databases && (ws.info.databases.length > 1 || ws.info.engine === "mysql" || ws.info.engine === "mariadb")
          Layout.preferredWidth: 220
          showLabel: false
          options: !ws.info ? [] : (ws.info.engine === "mysql" || ws.info.engine === "mariadb")
            ? [{ value: "", label: "All databases" }].concat(ws.info.databases) : ws.info.databases
          value: ws.info ? ws.info.database : ""
          onChanged: function(v) { if (v !== ws.info.database) ws.switchDatabase(v) }
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 0

      Sidebar {
        Layout.preferredWidth: 260
        Layout.fillHeight: true
        tree: ws.tree
        loading: ws.treeLoading
        onOpenRequested: function(schema, table) { ws.openTable(schema, table) }
        onRefreshRequested: ws.loadTree()
      }
      Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Qt.lighter(Color.background, 1.5) }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 0

        // ---- tab strip ----
        Flickable {
          Layout.fillWidth: true
          implicitHeight: tabsRow.implicitHeight
          visible: tabModel.count > 0
          contentWidth: tabsRow.implicitWidth
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          Row {
            id: tabsRow
            Repeater {
              model: tabModel
              delegate: Rectangle {
                required property int index
                required property string schema
                required property string table
                readonly property var page: tabStack.itemAt(index)
                implicitWidth: tabLabel.implicitWidth + closeBtn.implicitWidth + 24
                implicitHeight: Math.round(Style.font.body * 2.4)
                color: index === ws.current ? Color.background : Qt.lighter(Color.background, 1.1)
                Rectangle { visible: index === ws.current; width: parent.width; height: 2; color: Color.accent }
                Text {
                  id: tabLabel
                  x: 12
                  anchors.verticalCenter: parent.verticalCenter
                  text: (page && page.dirty ? "● " : "") + table
                  color: index === ws.current ? Color.foreground : Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                  onClicked: function(mouse) { if (mouse.button === Qt.MiddleButton) ws.closeTab(index); else ws.current = index }
                }
                Ui.Button {
                  id: closeBtn
                  anchors.right: parent.right
                  anchors.rightMargin: 4
                  anchors.verticalCenter: parent.verticalCenter
                  text: "✕"
                  fontSize: Style.font.bodySmall
                  tooltipText: "Close (Ctrl+W)"
                  onClicked: ws.closeTab(index)
                }
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.lighter(Color.background, 1.4) }
              }
            }
          }
        }

        StackLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          currentIndex: ws.current
          Repeater {
            id: tabStack
            model: tabModel
            delegate: TableTab {
              required property int index
              required property var model
              schema: model.schema
              table: model.table
              helper: ws.helper
              sid: ws.info.session
              active: ws.visible && index === ws.current
              onNotify: function(text) { ws.toast = text }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: tabModel.count === 0
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: "Pick a table on the left"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  Rectangle {
    visible: ws.toast !== ""
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 48
    width: Math.min(toastText.implicitWidth + 32, parent.width - 40)
    height: toastText.implicitHeight + 16
    radius: 6
    color: Color.popups.background
    border.color: Color.popups.border
    Text {
      id: toastText
      anchors.centerIn: parent
      width: parent.width - 32
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: ws.toast
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }
}
