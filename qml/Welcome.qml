import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// TablePlus-style start screen: connections on the left, the form on the right.
Item {
  id: welcome
  property var helper: null
  property var connections: []
  property var omadbServers: []
  property bool keyring: true
  property string search: ""
  property string selectedId: ""
  property string toast: ""

  signal connectRequested(var conn)

  readonly property var tagOrder: ["production", "staging", "development", "local"]
  readonly property var tagColors: ({ production: "#e05252", staging: "#e0a352", development: "#52a3e0", local: "#7a8a7a" })
  readonly property var engineIcons: ({ postgresql: "", mysql: "", mariadb: "", sqlite: "",
    redis: "", valkey: "", mongodb: "" })

  function reload() {
    helper.request("conn.list", {}, function(result, error) {
      if (error) { toast = error.message; return }
      connections = result.connections
      omadbServers = result.omadb
      keyring = result.keyring
    })
  }

  function matches(c) {
    const q = search.toLowerCase()
    return q === "" || (c.name + " " + c.host + " " + c.engine + " " + c.database).toLowerCase().indexOf(q) !== -1
  }

  // Rows for the list: a header per group, then its connections.
  readonly property var rows: {
    const out = []
    const omadb = omadbServers.filter(matches)
    if (omadb.length) {
      out.push({ header: "OmaDBngin" })
      omadb.forEach(function(c) { out.push({ conn: c }) })
    }
    tagOrder.forEach(function(tag) {
      const group = connections.filter(function(c) { return c.tag === tag && matches(c) })
      if (!group.length) return
      out.push({ header: tag.charAt(0).toUpperCase() + tag.slice(1) })
      group.forEach(function(c) { out.push({ conn: c }) })
    })
    return out
  }

  function select(c) {
    selectedId = c ? c.id : ""
    form.visible = true
    form.load(c)
  }

  function subtitle(c) {
    if (c.engine === "sqlite") return c.path
    return (c.user ? c.user + "@" : "") + c.host + ":" + c.port + (c.database ? "/" + c.database : "")
  }

  Component.onCompleted: if (helper && helper.status === "ready") reload()  // else onStatusChanged loads it

  Connections {
    target: welcome.helper
    function onStatusChanged() { if (welcome.helper.status === "ready") welcome.reload() }
  }

  RowLayout {
    anchors.fill: parent
    spacing: 0

    // ---- connection list ----
    Rectangle {
      Layout.preferredWidth: 340
      Layout.fillHeight: true
      color: Qt.darker(Color.background, 1.15)

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
          Layout.fillWidth: true
          Ui.TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Search connections"
            font.family: Style.font.family
            onTextChanged: welcome.search = text
            Keys.onDownPressed: list.forceActiveFocus()
          }
          Ui.Button { bordered: true; text: "+"; tooltipText: "New connection"; onClicked: welcome.select(null) }
        }

        ListView {
          id: list
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          model: welcome.rows
          keyNavigationEnabled: true
          Keys.onReturnPressed: {
            const r = welcome.rows[currentIndex]
            if (r && r.conn) welcome.connectRequested(r.conn)
          }

          Text {
            y: 8
            width: list.width
            visible: welcome.rows.length === 0
            text: welcome.search ? "No matches" : "No connections yet. Press + to add one."
            color: Color.muted
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          delegate: Item {
            required property var modelData
            required property int index
            width: list.width
            height: modelData.header ? 28 : 52

            Text {
              visible: !!modelData.header
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 4
              text: modelData.header || ""
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Rectangle {
              visible: !modelData.header
              anchors.fill: parent
              anchors.topMargin: 2
              anchors.bottomMargin: 2
              radius: 6
              color: modelData.conn && modelData.conn.id === welcome.selectedId
                ? Qt.lighter(Color.background, 1.5) : hover.containsMouse ? Qt.lighter(Color.background, 1.25) : "transparent"

              Rectangle { width: 4; height: parent.height - 12; anchors.verticalCenter: parent.verticalCenter; x: 4; radius: 2
                color: modelData.conn ? modelData.conn.color : "transparent" }

              Text {
                id: icon
                x: 16
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.conn ? (welcome.engineIcons[modelData.conn.engine] || "") : ""
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body * 1.6
              }
              Column {
                anchors.left: icon.right
                anchors.leftMargin: 12
                anchors.right: badge.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  text: modelData.conn ? modelData.conn.name : ""
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  text: modelData.conn ? welcome.subtitle(modelData.conn) : ""
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
              Text {
                id: badge
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: !modelData.conn ? "" : modelData.conn.source === "omadb" ? (modelData.conn.running ? "●" : "○")
                  : modelData.conn.ssh ? "" : ""
                color: modelData.conn && modelData.conn.source === "omadb" && modelData.conn.running ? "#5fb85f" : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: welcome.select(modelData.conn)
                onDoubleClicked: welcome.connectRequested(modelData.conn)
              }
            }
          }
        }

      }
    }

    // ---- form / empty state ----
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      Column {
        anchors.centerIn: parent
        visible: !form.visible
        spacing: 8
        Image {
          anchors.horizontalCenter: parent.horizontalCenter
          source: Qt.resolvedUrl("../icon.svg")
          width: 88
          height: 88
          sourceSize: Qt.size(176, 176)
          opacity: 0.85
        }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Select a connection, or press + to create one"
          color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body }
      }

      ConnectionForm {
        id: form
        anchors.fill: parent
        visible: false
        helper: welcome.helper
        keyring: welcome.keyring
        onSaved: function(c) { welcome.reload(); welcome.select(c); welcome.toast = "Saved " + c.name }
        onCancelled: { visible = false; welcome.selectedId = "" }
        onDeleted: function(id) { visible = false; welcome.selectedId = ""; welcome.reload() }
        onDuplicated: function(c) { welcome.reload(); welcome.select(c) }
        onConnectRequested: function(c) { welcome.connectRequested(c) }
      }
    }
  }

  // ---- toast ----
  Rectangle {
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottomMargin: 16
    visible: welcome.toast !== ""
    width: toastText.implicitWidth + 24
    height: toastText.implicitHeight + 12
    radius: 6
    color: Qt.lighter(Color.background, 1.6)
    Text { id: toastText; anchors.centerIn: parent; text: welcome.toast; color: Color.foreground
      font.family: Style.font.family; font.pixelSize: Style.font.body }
    Timer { running: welcome.toast !== ""; interval: 3000; onTriggered: welcome.toast = "" }
  }
}
