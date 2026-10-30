import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
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

  // The dropdown sets its own value when picked; put the binding back.
  function resetDatabase() { dbBox.value = Qt.binding(function() { return bar.info ? bar.info.database : "" }) }

  implicitHeight: titleRow.implicitHeight + 12
  color: Qt.lighter(Commons.Color.background, 1.12)
  Rectangle { width: parent.width; height: 3; color: bar.info ? bar.info.color : "transparent" }
  RowLayout {
    id: titleRow
    x: 10
    width: parent.width - 20
    anchors.verticalCenter: parent.verticalCenter
    spacing: 10
    Ui.Button { text: "‹ Connections"; tooltipText: "Close this connection"; onClicked: bar.closeRequested() }
    Text {
      textFormat: Text.PlainText
      text: bar.info ? bar.info.name : ""
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    Rectangle {
      visible: bar.info && !!bar.info.readonly
      implicitWidth: roText.implicitWidth + 12
      implicitHeight: roText.implicitHeight + 4
      radius: 3
      color: Qt.lighter(Commons.Color.background, 1.6)
      Text { textFormat: Text.PlainText; id: roText; anchors.centerIn: parent; text: "READ-ONLY"; color: Commons.Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true }
    }
    Rectangle {
      visible: bar.info && bar.info.tag === "production"
      implicitWidth: prodText.implicitWidth + 12
      implicitHeight: prodText.implicitHeight + 4
      radius: 3
      color: "#c94040"
      Text { textFormat: Text.PlainText; id: prodText; anchors.centerIn: parent; text: "PRODUCTION"; color: "white"; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true }
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      elide: Text.ElideRight
      text: bar.info ? bar.info.version + (bar.info.ssh ? "  ·   SSH" : "") : ""
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout { id: extra; spacing: 6 }
    Text {
      textFormat: Text.PlainText
      visible: bar.showDatabases
      text: "Database"
      color: Commons.Color.muted
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
