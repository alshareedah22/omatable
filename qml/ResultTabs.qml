import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// One tab per statement of the last run: a grid for rows, a line for
// affected rows, the message for an error (always the last one).
Item {
  id: rt

  property var results: []
  property int current: 0
  property string placeholder: "Run a query with Ctrl+Enter"
  readonly property var shown: results.length ? results[Math.min(current, results.length - 1)] : null
  signal notify(string text)

  onResultsChanged: {
    // open the error if there is one, else the last result with rows
    let pick = results.length - 1
    if (pick >= 0 && !results[pick].error) {
      for (let i = results.length - 1; i >= 0; i--) if (results[i].columns) { pick = i; break }
    }
    current = Math.max(0, pick)
  }

  function summary(r) {
    if (r.error) return r.error.code === "cancelled" ? "Cancelled" : "Error"
    if (r.columns) return r.rows.length.toLocaleString(Qt.locale(), "f", 0) + (r.truncated ? "+" : "") + (r.rows.length === 1 && !r.truncated ? " row" : " rows")
    return r.affected >= 0 ? r.affected + (r.affected === 1 ? " row affected" : " rows affected") : "Done"
  }

  ResultModel {
    id: model
    result: rt.shown && rt.shown.columns ? rt.shown : null
    onNotify: function(text) { rt.notify(text) }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    Flickable {
      Layout.fillWidth: true
      implicitHeight: tabsRow.implicitHeight
      visible: rt.results.length > 1
      contentWidth: tabsRow.implicitWidth
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Row {
        id: tabsRow
        Repeater {
          model: rt.results
          delegate: Rectangle {
            required property int index
            required property var modelData
            implicitWidth: label.implicitWidth + 20
            implicitHeight: Math.round(Style.font.body * 2.1)
            color: index === rt.current ? Color.background : Qt.lighter(Color.background, 1.1)
            Rectangle { visible: index === rt.current; width: parent.width; height: 2; color: modelData.error ? Color.urgent : Color.accent }
            Text {
              id: label
              anchors.centerIn: parent
              text: (index + 1) + " · " + rt.summary(modelData)
              color: modelData.error ? Color.urgent : index === rt.current ? Color.foreground : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea { anchors.fill: parent; onClicked: rt.current = index }
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.lighter(Color.background, 1.4) }
          }
        }
      }
    }

    DataGrid {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: rt.shown !== null && rt.shown.columns !== undefined
      tab: model
    }

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: !rt.shown || rt.shown.columns === undefined
      Column {
        x: 16
        y: 16
        width: parent.width - 32
        spacing: 8
        Text {
          width: parent.width
          text: !rt.shown ? rt.placeholder
            : rt.shown.error ? rt.shown.error.message
            : rt.summary(rt.shown)
          color: rt.shown && rt.shown.error && rt.shown.error.code !== "cancelled" ? Color.urgent : Color.muted
          wrapMode: Text.Wrap
          // monospace keeps PostgreSQL's ^ under the right character
          font.family: rt.shown && rt.shown.error ? "monospace" : Style.font.family
          font.pixelSize: Style.font.body
        }
        Text {
          visible: rt.shown !== null
          width: parent.width
          text: rt.shown ? rt.shown.sql : ""
          color: Color.muted
          wrapMode: Text.Wrap
          maximumLineCount: 6
          elide: Text.ElideRight
          font.family: "monospace"
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      visible: rt.shown !== null
      implicitHeight: statusText.implicitHeight + 10
      color: Qt.lighter(Color.background, 1.08)
      Text {
        id: statusText
        x: 8
        width: parent.width - 16
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: !rt.shown ? "" : rt.summary(rt.shown) + " · " + rt.shown.ms + " ms"
          + (rt.shown.truncated ? " · first " + rt.shown.rows.length.toLocaleString(Qt.locale(), "f", 0) + " rows shown" : "")
          + "   " + rt.shown.sql.replace(/\s+/g, " ")
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
