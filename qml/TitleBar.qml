import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// The strip above every browser: back to the connections, the connection's
// name, tag and version, the caller's buttons, and a database picker.
Rectangle {
  id: bar

  property var info: null
  property var databaseOptions: []
  property bool showDatabases: databaseOptions.length > 1
  default property alias buttons: extra.data
  signal closeRequested()
  signal databaseChosen(string database)

  function resetDatabase() { dbBox.value = info ? info.database : "" }

  implicitHeight: titleRow.implicitHeight + 12
  color: Qt.lighter(Color.background, 1.12)
  Rectangle { width: parent.width; height: 3; color: bar.info ? bar.info.color : "transparent" }
  RowLayout {
    id: titleRow
    x: 10
    width: parent.width - 20
    anchors.verticalCenter: parent.verticalCenter
    spacing: 10
    Ui.Button { text: "‹ Connections"; tooltipText: "Close this connection"; onClicked: bar.closeRequested() }
    Text {
      text: bar.info ? bar.info.name : ""
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    Rectangle {
      visible: bar.info && bar.info.tag === "production"
      implicitWidth: prodText.implicitWidth + 12
      implicitHeight: prodText.implicitHeight + 4
      radius: 3
      color: "#c94040"
      Text { id: prodText; anchors.centerIn: parent; text: "PRODUCTION"; color: "white"; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true }
    }
    Text {
      Layout.fillWidth: true
      elide: Text.ElideRight
      text: bar.info ? bar.info.version + (bar.info.ssh ? "  ·   SSH" : "") : ""
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout { id: extra; spacing: 6 }
    Text {
      visible: bar.showDatabases
      text: "Database"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Ui.Dropdown {
      id: dbBox
      visible: bar.showDatabases
      Layout.preferredWidth: 220
      showLabel: false
      options: bar.databaseOptions
      value: bar.info ? bar.info.database : ""
      onChanged: function(v) { if (bar.info && v !== bar.info.database) bar.databaseChosen(v) }
    }
  }
}
