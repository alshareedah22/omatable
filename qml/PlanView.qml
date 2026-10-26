import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui as Ui

// A query plan as a tree: each step with its estimated cost and rows, and
// with Analyze its real rows and time. Engines report a step's cost and time
// including its children, so the bar and the red marking use what the step
// itself adds (time when analyzed, else cost). Click a step for details.
Popup {
  id: dlg

  property var helper: null
  property string sid: ""
  property string engine: ""
  property string text: ""
  property var cursor: null
  property var plan: null
  property bool busy: false
  property bool raw: false
  property string error: ""
  property var open_: ({})        // row index -> details shown
  signal notify(string message)

  readonly property bool canAnalyze: engine !== "sqlite"
  readonly property var rows: {
    const out = []
    if (!plan) return out
    function hasTime(n) { return n.time_ms !== null && n.time_ms !== undefined || n.children.some(hasTime) }
    const timedPlan = plan.nodes.some(hasTime)
    function value(n) { return (timedPlan ? n.time_ms : n.cost) || 0 }
    function walk(n, depth) {
      let kids = 0
      for (const c of n.children) kids += value(c)
      out.push({ n: n, depth: depth, self: Math.max(0, value(n) - kids) })
      for (const c of n.children) walk(c, depth + 1)
    }
    for (const n of plan.nodes) walk(n, 0)
    return out
  }
  readonly property bool timed: rows.some(function(r) { return r.n.time_ms !== null && r.n.time_ms !== undefined })
  readonly property real top: {
    let m = 0
    for (const r of rows) m = Math.max(m, r.self)
    return m
  }

  function show(sqlText, cur) {
    text = sqlText
    cursor = cur
    raw = false
    open_ = ({})
    open()
    run(false)
  }

  function run(analyze) {
    busy = true
    error = ""
    const params = { session: sid, text: text, analyze: analyze }
    if (cursor !== null) params.cursor = cursor
    helper.request("query.explain", params, function(r, e) {
      busy = false
      if (e) { error = e.message; return }
      plan = r
      open_ = ({})
    })
  }

  function num(v) {
    if (v === null || v === undefined) return ""
    return v >= 1000000 ? (v / 1000000).toFixed(1) + "M" : v >= 10000 ? Math.round(v / 1000) + "k"
      : Number.isInteger(v) ? String(v) : v.toFixed(v < 10 ? 2 : 1)
  }
  function ms(v) { return v === null || v === undefined ? "" : v < 1 ? v.toFixed(3) + " ms" : v < 1000 ? v.toFixed(1) + " ms" : (v / 1000).toFixed(2) + " s" }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 40 : 900, 1000)
  height: Math.min(parent ? parent.height - 40 : 700, 800)
  padding: 16
  modal: true
  focus: true
  closePolicy: Popup.CloseOnEscape
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  component Cell: Text {
    color: Color.muted
    font.family: "monospace"
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignRight
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 8

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Text {
        text: dlg.plan && dlg.plan.analyze ? "Query plan · analyzed" : "Query plan"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: !dlg.plan ? "" : [dlg.plan.summary && dlg.plan.summary.planning_ms != null ? "planning " + dlg.ms(dlg.plan.summary.planning_ms) : "",
                                dlg.plan.summary && dlg.plan.summary.execution_ms != null ? "execution " + dlg.ms(dlg.plan.summary.execution_ms) : ""]
                                .filter(function(x) { return x }).join("  ·  ")
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button {
        visible: dlg.canAnalyze
        bordered: true
        enabled: !dlg.busy
        text: "Analyze"
        tooltipText: "Run the query to measure real rows and time (PostgreSQL rolls it back)"
        onClicked: dlg.run(true)
      }
      Ui.Button { bordered: true; enabled: !dlg.busy; text: "Estimate"; visible: dlg.plan && dlg.plan.analyze; onClicked: dlg.run(false) }
      Ui.Button { bordered: true; selected: dlg.raw; text: "Raw"; tooltipText: "The server's own output"; onClicked: dlg.raw = !dlg.raw }
      Ui.Button {
        bordered: true
        text: "Copy"
        enabled: dlg.plan !== null
        onClicked: { Quickshell.execDetached(["wl-copy", "--", dlg.plan.raw]); dlg.notify("Copied the plan") }
      }
    }
    Text {
      Layout.fillWidth: true
      visible: dlg.plan !== null
      text: dlg.plan ? dlg.plan.sql.replace(/\s+/g, " ") : ""
      elide: Text.ElideRight
      color: Color.muted
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      Layout.fillWidth: true
      visible: dlg.error !== ""
      text: dlg.error
      wrapMode: Text.Wrap
      color: Color.urgent
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }

    // ---- header ----
    RowLayout {
      Layout.fillWidth: true
      visible: !dlg.raw && dlg.plan !== null
      spacing: 8
      Text { Layout.fillWidth: true; text: "Step"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true }
      Cell { Layout.preferredWidth: 70; text: "cost"; font.bold: true }
      Cell { Layout.preferredWidth: 70; text: "rows"; font.bold: true }
      Cell { Layout.preferredWidth: 70; visible: dlg.timed; text: "actual"; font.bold: true }
      Cell { Layout.preferredWidth: 80; visible: dlg.timed; text: "time"; font.bold: true }
      Item { Layout.preferredWidth: 90 }
    }

    ListView {
      id: list
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: !dlg.raw
      clip: true
      model: dlg.rows
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property var n: modelData.n
        readonly property bool shown: !!dlg.open_[index]
        readonly property real share: dlg.top > 0 ? modelData.self / dlg.top : 0
        width: list.width
        height: line.implicitHeight + (shown ? details.implicitHeight + 6 : 0) + 8
        color: hover.hovered ? Qt.lighter(Color.background, 1.15) : "transparent"
        HoverHandler { id: hover }
        TapHandler { onTapped: { const o = Object.assign({}, dlg.open_); o[row.index] = !o[row.index]; dlg.open_ = o } }
        RowLayout {
          id: line
          x: 4
          y: 4
          width: parent.width - 8
          spacing: 8
          Text {
            Layout.fillWidth: true
            leftPadding: row.modelData.depth * 18
            elide: Text.ElideRight
            text: (row.n.children.length ? "└ " : "· ") + row.n.label
            color: row.share > 0.5 ? Color.urgent : Color.foreground
            font.family: "monospace"
            font.pixelSize: Style.font.bodySmall
            font.bold: row.share > 0.5
          }
          Cell { Layout.preferredWidth: 70; text: dlg.num(row.n.cost) }
          Cell { Layout.preferredWidth: 70; text: dlg.num(row.n.rows) }
          Cell {
            Layout.preferredWidth: 70
            visible: dlg.timed
            text: dlg.num(row.n.actual_rows) + (row.n.loops > 1 ? " ×" + row.n.loops : "")
            // estimates off by 10× or more are worth a look
            color: row.n.rows && row.n.actual_rows !== null && (row.n.actual_rows > row.n.rows * 10 || row.n.actual_rows * 10 < row.n.rows)
              ? Color.urgent : Color.muted
          }
          Cell { Layout.preferredWidth: 80; visible: dlg.timed; text: dlg.ms(row.n.time_ms) }
          Rectangle {
            Layout.preferredWidth: 90
            implicitHeight: 6
            radius: 3
            color: Qt.lighter(Color.background, 1.4)
            Rectangle { width: parent.width * Math.min(1, row.share); height: parent.height; radius: 3; color: row.share > 0.5 ? Color.urgent : Color.accent }
          }
        }
        Column {
          id: details
          visible: row.shown
          x: 22 + row.modelData.depth * 18
          y: line.y + line.implicitHeight + 4
          width: parent.width - x - 8
          Repeater {
            model: row.n.detail
            delegate: Text {
              required property var modelData
              width: details.width
              wrapMode: Text.Wrap
              text: (modelData[0] ? modelData[0] + ": " : "") + modelData[1]
              color: Color.muted
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
            }
          }
          Text {
            visible: row.n.detail.length === 0
            text: "No more details"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
      Text {
        anchors.centerIn: parent
        visible: dlg.busy
        text: "Working…"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
    ScrollView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: dlg.raw
      TextArea {
        readOnly: true
        selectByMouse: true
        text: dlg.plan ? dlg.plan.raw : ""
        wrapMode: TextEdit.NoWrap
        color: Color.foreground
        font.family: "monospace"
        font.pixelSize: Style.font.bodySmall
        background: Rectangle { color: Qt.darker(Color.background, 1.15) }
      }
    }
    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: "Click a step for its details. Red: the most expensive steps, and row estimates off by 10× or more."
        color: Color.muted
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Ui.Button { text: "Close"; onClicked: dlg.close() }
    }
  }
}
