import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// One tab per statement of the last run: a grid for rows, a line for
// affected rows, the message for an error (always the last one).
Item {
  id: rt

  property var helper: null
  property string sid: ""
  property string engine: ""
  readonly property bool dirty: model.dirty
  property var results: []
  property int current: 0
  property string placeholder: "Run a query with Ctrl+Enter"
  readonly property var shown: results.length ? results[Math.min(current, results.length - 1)] : null
  signal notify(string text)
  signal exportRequested(string sql)

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
    engine: rt.engine
    onNotify: function(text) { rt.notify(text) }
    onEditorRequested: function(r, c) { cellEditor.edit(r, c) }
  }
  CellEditor { id: cellEditor; tab: model }
  Confirm { id: confirm }

  function discardEdits() { model.discardAll() }

  function preview(then) {
    const src = model.source
    helper.request("table.preview", { session: sid, schema: src.schema, table: src.table, changes: model.changes() }, function(r, e) {
      if (e) { notify(e.message); return }
      then(r.statements)
    })
  }
  function commit() {
    const src = model.source
    preview(function(stmts) {
      confirm.ask({ title: "Save " + stmts.length + (stmts.length === 1 ? " change" : " changes") + " to " + src.table + "?",
                    detail: stmts.join("\n"), confirm: "Commit" }, function(dlg) {
        helper.request("table.commit", { session: sid, schema: src.schema, table: src.table, changes: model.changes(), confirmed: true }, function(r, e) {
          if (e) { dlg.fail(e.message); return }
          dlg.done()
          model.applied()
          notify("Saved " + stmts.length + (stmts.length === 1 ? " change" : " changes") + " to " + src.table)
        })
      })
    })
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
            color: index === rt.current ? Commons.Color.background : Qt.lighter(Commons.Color.background, 1.1)
            Rectangle { visible: index === rt.current; width: parent.width; height: 2; color: modelData.error ? Commons.Color.urgent : Commons.Color.accent }
            Text {
              id: label
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: (index + 1) + " · " + rt.summary(modelData)
              color: modelData.error ? Commons.Color.urgent : index === rt.current ? Commons.Color.foreground : Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea { anchors.fill: parent; onClicked: { if (model.dirty && index !== rt.current) rt.notify("Commit or discard the edits first"); else rt.current = index } }
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.lighter(Commons.Color.background, 1.4) }
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
          textFormat: Text.PlainText
          width: parent.width
          text: !rt.shown ? rt.placeholder
            : rt.shown.error ? rt.shown.error.message
            : rt.summary(rt.shown)
          color: rt.shown && rt.shown.error && rt.shown.error.code !== "cancelled" ? Commons.Color.urgent : Commons.Color.muted
          wrapMode: Text.Wrap
          // monospace keeps PostgreSQL's ^ under the right character
          font.family: rt.shown && rt.shown.error ? "monospace" : Style.font.family
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          visible: rt.shown !== null
          width: parent.width
          text: rt.shown ? rt.shown.sql : ""
          color: Commons.Color.muted
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
      color: Qt.lighter(Commons.Color.background, 1.08)
      Row {
        id: editBar
        anchors.right: exportBtn.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        visible: model.dirty
        Ui.Button { bordered: true; text: "Discard"; fontSize: Style.font.bodySmall; onClicked: model.discardAll() }
        Ui.Button { bordered: true; foreground: Commons.Color.accent; fontSize: Style.font.bodySmall
                    text: "Commit " + model.changeCount + (model.changeCount === 1 ? " change" : " changes"); onClicked: rt.commit() }
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: exportBtn.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        visible: !model.dirty && model.editable
        text: "editable · " + (model.source ? model.source.table : "")
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button {
        id: exportBtn
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        visible: rt.shown !== null && rt.shown.columns !== undefined
        text: "Export"
        fontSize: Style.font.bodySmall
        tooltipText: "Run this statement again and save all its rows to a file"
        onClicked: rt.exportRequested(rt.shown.sql)
      }
      Text {
        id: statusText
        textFormat: Text.PlainText
        x: 8
        width: parent.width - 16 - (exportBtn.visible ? exportBtn.width + 8 : 0) - (editBar.visible ? editBar.width + 8 : model.editable ? 140 : 0)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: !rt.shown ? "" : rt.summary(rt.shown) + " · " + rt.shown.ms + " ms"
          + (rt.shown.truncated ? " · first " + rt.shown.rows.length.toLocaleString(Qt.locale(), "f", 0) + " rows shown" : "")
          + "   " + rt.shown.sql.replace(/\s+/g, " ")
        color: Commons.Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
