import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// A SQL query: editor on top, one result tab per statement below, and a
// drawer with the connection's history and the saved queries.
Item {
  id: q

  property var helper: null
  property string sid: ""
  property string engine: ""
  property string connId: ""
  property var palette: ({})
  property bool active: false
  readonly property bool dirty: false

  property bool running: false
  property real startedAt: 0
  property real elapsed: 0
  property var results: []
  property string error: ""

  property bool drawerOpen: false
  property string drawerPage: "history"
  property var historyItems: []
  property var savedItems: []
  property string savedId: ""
  property string savedName: ""

  signal notify(string text)
  signal ddlRan()
  signal databaseReported(string database)

  function run(all) {
    if (running) return
    const text = editor.text
    const params = { session: sid }
    if (!all && editor.selectionEnd > editor.selectionStart) params.text = text.substring(editor.selectionStart, editor.selectionEnd)
    else {
      params.text = text
      if (!all) params.cursor = editor.cursorPosition
    }
    running = true
    startedAt = Date.now()
    elapsed = 0
    error = ""
    results = []
    helper.request("query.run", params, function(r, e) {
      running = false
      if (e) { error = e.message; results = []; return }
      results = r.results
      if (r.ddl) q.ddlRan()
      q.databaseReported(r.database)
      if (drawerOpen && drawerPage === "history") loadHistory()
    })
  }

  function cancel() {
    if (running) helper.request("query.cancel", { session: sid })
  }

  function loadHistory() {
    helper.request("query.history", { conn: connId, search: historySearch.text, limit: 200 }, function(r, e) {
      if (!e) historyItems = r.items
    })
  }

  function loadSaved() {
    helper.request("query.saved", {}, function(r, e) { if (!e) savedItems = r.items })
  }

  function openDrawer(page) {
    drawerPage = page
    drawerOpen = true
    if (page === "history") loadHistory(); else loadSaved()
  }

  function load(sql, saved) {
    editor.replaceAll(sql)
    savedId = saved ? saved.id : ""
    savedName = saved ? saved.name : ""
  }

  function save(name) {
    helper.request("query.save", { name: name, sql: editor.text, id: savedId || null }, function(r, e) {
      if (e) { notify(e.message); return }
      savedId = r.id
      savedName = r.name
      savePopup.close()
      notify("Saved “" + r.name + "”")
      if (drawerOpen && drawerPage === "saved") loadSaved()
    })
  }

  function when(ts) {
    const d = new Date(ts)
    const today = new Date()
    return d.toDateString() === today.toDateString()
      ? d.toLocaleTimeString(Qt.locale(), "HH:mm") : d.toLocaleDateString(Qt.locale(), "d MMM") + " " + d.toLocaleTimeString(Qt.locale(), "HH:mm")
  }

  Timer { interval: 100; repeat: true; running: q.running; onTriggered: q.elapsed = (Date.now() - q.startedAt) / 1000 }

  Shortcut { sequences: ["Ctrl+Return", "Ctrl+Enter"]; enabled: q.active; onActivated: q.run(false) }
  Shortcut { sequences: ["Ctrl+Shift+Return", "Ctrl+Shift+Enter"]; enabled: q.active; onActivated: q.run(true) }
  Shortcut { sequences: [StandardKey.Save]; enabled: q.active; onActivated: savePopup.open() }
  Shortcut { sequence: "Ctrl+H"; enabled: q.active; onActivated: { if (q.drawerOpen) q.drawerOpen = false; else q.openDrawer("history") } }
  Shortcut { sequence: "Ctrl+."; enabled: q.active && q.running; onActivated: q.cancel() }

  onActiveChanged: if (active) editor.focusEditor()
  Component.onCompleted: editor.focusEditor()

  RowLayout {
    anchors.fill: parent
    spacing: 0

    ColumnLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 0

      // ---- toolbar ----
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: bar.implicitHeight + 10
        color: Qt.lighter(Color.background, 1.08)
        clip: true
        RowLayout {
          id: bar
          x: 8
          width: parent.width - 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6
          Ui.Button { bordered: true; foreground: Color.accent; text: "▶ Run"; tooltipText: "Run the statement at the cursor, or the selection (Ctrl+Enter)"; enabled: !q.running; onClicked: q.run(false) }
          Ui.Button { bordered: true; text: "Run all"; tooltipText: "Ctrl+Shift+Enter"; enabled: !q.running; onClicked: q.run(true) }
          Ui.Button { visible: q.running; bordered: true; foreground: Color.urgent; text: "■ Cancel"; tooltipText: "Ctrl+."; onClicked: q.cancel() }
          Text {
            visible: q.running
            text: "Running… " + q.elapsed.toFixed(1) + " s"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Item { Layout.fillWidth: true }
          Text {
            visible: q.savedName !== ""
            text: q.savedName
            color: Color.muted
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.maximumWidth: implicitWidth
            horizontalAlignment: Text.AlignRight
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Ui.Button { bordered: true; text: "Save"; tooltipText: "Save this query (Ctrl+S)"; onClicked: savePopup.open() }
          Ui.Button { bordered: true; selected: q.drawerOpen; text: "History"; tooltipText: "History and saved queries (Ctrl+H)"; onClicked: { if (q.drawerOpen) q.drawerOpen = false; else q.openDrawer(q.drawerPage) } }
        }
      }

      SplitView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        orientation: Qt.Vertical
        handle: Rectangle {
          implicitHeight: 5
          color: SplitHandle.pressed || SplitHandle.hovered ? Qt.alpha(Color.accent, 0.5) : Qt.lighter(Color.background, 1.3)
        }

        CodeEditor {
          id: editor
          SplitView.preferredHeight: parent ? parent.height * 0.42 : 300
          SplitView.minimumHeight: 80
          engine: q.engine
          palette: q.palette
          onRunCurrent: q.run(false)
          onRunAll: q.run(true)
        }

        ResultTabs {
          SplitView.fillHeight: true
          SplitView.minimumHeight: 80
          results: q.results
          placeholder: q.error ? q.error : q.running ? "Running…" : "Ctrl+Enter runs the statement at the cursor (or the selection), Ctrl+Shift+Enter runs them all"
          onNotify: function(text) { q.notify(text) }
        }
      }
    }

    // ---- drawer: history and saved queries ----
    Rectangle {
      Layout.fillHeight: true
      Layout.preferredWidth: Math.min(300, q.width * 0.4)
      visible: q.drawerOpen
      color: Qt.lighter(Color.background, 1.05)
      Rectangle { width: 1; height: parent.height; color: Qt.lighter(Color.background, 1.5) }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        anchors.leftMargin: 9
        spacing: 6

        RowLayout {
          Layout.fillWidth: true
          spacing: 4
          Ui.Button { bordered: q.drawerPage === "history"; text: "History"; onClicked: q.openDrawer("history") }
          Ui.Button { bordered: q.drawerPage === "saved"; text: "Saved"; onClicked: q.openDrawer("saved") }
          Item { Layout.fillWidth: true }
          Ui.Button {
            visible: q.drawerPage === "history" && q.historyItems.length > 0
            text: "Clear"
            tooltipText: "Forget this connection's history"
            onClicked: helper.request("query.history_clear", { conn: q.connId }, function() { q.loadHistory() })
          }
          Ui.Button { text: "✕"; tooltipText: "Close (Ctrl+H)"; onClicked: q.drawerOpen = false }
        }

        Ui.TextField {
          id: historySearch
          Layout.fillWidth: true
          visible: q.drawerPage === "history"
          placeholderText: "Search history"
          font.family: Style.font.family
          onTextEdited: searchTimer.restart()
          Timer { id: searchTimer; interval: 250; onTriggered: q.loadHistory() }
        }

        ListView {
          id: drawerList
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: 2
          model: q.drawerPage === "history" ? q.historyItems : q.savedItems
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          delegate: Rectangle {
            id: entry
            required property var modelData
            width: drawerList.width
            implicitHeight: entryCol.implicitHeight + 10
            radius: 4
            color: entryHover.hovered ? Qt.lighter(Color.background, 1.25) : "transparent"
            HoverHandler { id: entryHover }
            Column {
              id: entryCol
              x: 6
              y: 5
              width: parent.width - 12 - (delBtn.visible ? delBtn.width : 0)
              spacing: 2
              Text {
                visible: q.drawerPage === "saved"
                width: parent.width
                text: entry.modelData.name || ""
                color: Color.foreground
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                text: String(entry.modelData.sql || "").replace(/\s+/g, " ")
                color: q.drawerPage === "saved" ? Color.muted : Color.foreground
                elide: Text.ElideRight
                maximumLineCount: q.drawerPage === "history" ? 2 : 1
                wrapMode: Text.WrapAnywhere
                font.family: "monospace"
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: q.drawerPage === "history"
                width: parent.width
                text: q.drawerPage !== "history" ? ""
                  : (entry.modelData.ok ? "✓ " : "✗ ") + q.when(entry.modelData.ts)
                    + (entry.modelData.database ? " · " + entry.modelData.database : "") + " · " + entry.modelData.ms + " ms"
                color: entry.modelData.ok ? Color.muted : Color.urgent
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: q.load(entry.modelData.sql, q.drawerPage === "saved" ? entry.modelData : null)
            }
            Ui.Button {
              id: delBtn
              visible: q.drawerPage === "saved"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              tooltipText: "Delete this saved query"
              onClicked: helper.request("query.delete_saved", { id: entry.modelData.id }, function(r, e) {
                if (e) q.notify(e.message)
                if (q.savedId === entry.modelData.id) { q.savedId = ""; q.savedName = "" }
                q.loadSaved()
              })
            }
          }
          Text {
            visible: drawerList.count === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: q.drawerPage === "history" ? "Queries you run on this connection show up here." : "Save a query with Ctrl+S to keep it here."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  Popup {
    id: savePopup
    anchors.centerIn: parent
    width: Math.min(parent.width - 80, 420)
    padding: 16
    modal: true
    focus: true
    background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }
    onOpened: { nameField.text = q.savedName; nameField.forceActiveFocus(); nameField.selectAll() }
    onClosed: editor.focusEditor()
    ColumnLayout {
      anchors.fill: parent
      spacing: 10
      Text { text: q.savedId ? "Save query" : "Save query as"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
      Ui.TextField {
        id: nameField
        Layout.fillWidth: true
        placeholderText: "Name"
        font.family: Style.font.family
        onAccepted: if (text.trim()) q.save(text.trim())
      }
      RowLayout {
        Item { Layout.fillWidth: true }
        Ui.Button { text: "Cancel"; onClicked: savePopup.close() }
        Ui.Button { bordered: true; foreground: Color.accent; text: "Save"; enabled: nameField.text.trim() !== ""; onClicked: q.save(nameField.text.trim()) }
      }
    }
  }
}
