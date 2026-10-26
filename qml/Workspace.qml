import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// An open session: title strip, schema sidebar and one tab per table or query.
Item {
  id: ws

  property var helper: null
  property var info: null          // session.open result
  property var tree: []
  property bool treeLoading: false
  property int current: -1
  property string toast: ""
  property var palette: ({})
  property int queryCount: 0
  property string downloads: ""
  signal closeRequested()

  readonly property bool dirty: {
    for (let i = 0; i < tabStack.count; i++) { const t = page(i); if (t && t.dirty) return true }
    return false
  }

  function page(i) {
    const loader = tabStack.itemAt(i)
    return loader ? loader.item : null
  }

  function loadTree() {
    treeLoading = true
    helper.request("schema.tree", { session: info.session }, function(r, e) {
      treeLoading = false
      if (e) { toast = e.message; return }
      tree = r.schemas
    })
  }

  function openTable(schema, table, view) {
    let i = 0
    for (; i < tabModel.count; i++) {
      const t = tabModel.get(i)
      if (t.kind === "table" && t.schema === schema && t.table === table) break
    }
    if (i === tabModel.count) tabModel.append({ kind: "table", schema: schema, table: table, title: table })
    current = i
    if (view) Qt.callLater(function() { const p = page(i); if (p) p.showView(view) })
  }

  function tabIndex(schema, table) {
    for (let i = 0; i < tabModel.count; i++) {
      const t = tabModel.get(i)
      if (t.kind === "table" && t.schema === schema && t.table === table) return i
    }
    return -1
  }

  function tableAction(act, schema, name, kind) {
    if (act === "open") openTable(schema, name)
    else if (act === "structure") openTable(schema, name, "structure")
    else if (act === "export") exportDialog.show({ schema: schema, table: name }, name)
    else if (act === "import") importDialog.show(schema, name)
    else if (act === "truncate" || act === "drop") {
      const i = tabIndex(schema, name)
      if (i >= 0 && page(i) && page(i).dirty) { current = i; toast = "Commit or discard the changes in " + name + " first"; return }
      const drop = act === "drop"
      confirm.ask({ title: (drop ? "Drop " + kind + " " : "Truncate ") + name + "?",
                    text: drop ? "This deletes the " + kind + (kind === "table" ? " and all its rows" : "") + ". It cannot be undone."
                               : "This deletes every row in " + name + ". It cannot be undone.",
                    confirm: drop ? "Drop " + kind : "Truncate", danger: true }, function(dlg) {
        const params = { session: info.session, schema: schema, table: name, confirmed: true }
        if (drop) params.kind = kind
        helper.request(drop ? "table.drop" : "table.truncate", params, function(r, e) {
          if (e) { dlg.fail(e.message); return }
          dlg.done()
          const j = tabIndex(schema, name)
          if (drop) { if (j >= 0) closeTab(j); loadTree() }
          else if (j >= 0 && page(j)) page(j).reload(true)
          toast = (drop ? "Dropped " : "Emptied ") + name
        })
      })
    }
  }

  function openQuery() {
    queryCount++
    tabModel.append({ kind: "query", schema: "", table: "", title: "Query " + queryCount })
    current = tabModel.count - 1
  }

  function followDatabase(db) {
    if (!info || db === info.database) return
    info = Object.assign({}, info, { database: db })
    loadTree()
  }

  // Run proceed() once nothing is staged, after asking to discard what is.
  function whenClean(proceed) {
    const names = []
    for (let i = 0; i < tabStack.count; i++) { const t = page(i); if (t && t.dirty) names.push(tabModel.get(i).title) }
    if (!names.length) { proceed(); return }
    confirm.ask({ title: "Discard unsaved changes?", text: "Staged changes in " + names.join(", ") + " have not been saved.",
                  confirm: "Discard", danger: true }, function(dlg) {
      dlg.done()
      for (let i = 0; i < tabStack.count; i++) { const t = page(i); if (t && t.dirty) t.discardAll() }
      proceed()
    })
  }

  function closeTab(i) {
    const t = page(i)
    if (t && t.dirty) {
      current = i
      confirm.ask({ title: "Discard changes to " + tabModel.get(i).title + "?", text: "The staged changes have not been saved.",
                    confirm: "Discard and close", danger: true }, function(dlg) {
        dlg.done()
        t.discardAll()
        closeTab(tabIndexOf(t))
      })
      return
    }
    if (t && t.running) t.cancel()
    tabModel.remove(i)
    current = Math.min(current >= i ? current - 1 : current, tabModel.count - 1)
    if (current < 0 && tabModel.count) current = 0
  }

  function tabIndexOf(p) {
    for (let i = 0; i < tabStack.count; i++) if (page(i) === p) return i
    return -1
  }

  function switchDatabase(db) {
    if (dirty) {
      titleBar.resetDatabase()
      whenClean(function() { switchDatabase(db) })
      return
    }
    helper.request("session.use", { session: info.session, database: db }, function(r, e) {
      if (e) { toast = e.message; titleBar.resetDatabase(); return }
      info = Object.assign({}, info, { database: r.database })
      titleBar.resetDatabase()
      // query tabs keep their text; table tabs belonged to the old database
      for (let i = tabModel.count - 1; i >= 0; i--) if (tabModel.get(i).kind === "table") tabModel.remove(i)
      current = tabModel.count ? 0 : -1
      loadTree()
    })
  }

  Component.onCompleted: {
    loadTree()
    helper.request("app.palette", {}, function(r, e) { if (!e) palette = r })
    helper.request("app.paths", {}, function(r, e) { if (!e) downloads = r.downloads })
  }

  Shortcut { sequence: "Ctrl+T"; enabled: ws.visible; onActivated: ws.openQuery() }
  Shortcut { sequence: "Ctrl+W"; enabled: ws.visible && ws.current >= 0; onActivated: ws.closeTab(ws.current) }
  Shortcut { sequence: "Ctrl+Tab"; enabled: ws.visible && tabModel.count > 1; onActivated: ws.current = (ws.current + 1) % tabModel.count }
  Shortcut { sequence: "Ctrl+Shift+Tab"; enabled: ws.visible && tabModel.count > 1; onActivated: ws.current = (ws.current - 1 + tabModel.count) % tabModel.count }

  ListModel { id: tabModel }
  Timer { id: toastTimer; interval: 4000; onTriggered: ws.toast = "" }
  onToastChanged: if (toast) toastTimer.restart()

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    TitleBar {
      id: titleBar
      Layout.fillWidth: true
      info: ws.info
      readonly property bool mysql: ws.info && (ws.info.engine === "mysql" || ws.info.engine === "mariadb")
      showDatabases: ws.info && ws.info.databases && (ws.info.databases.length > 1 || mysql)
      databaseOptions: !ws.info ? [] : mysql ? [{ value: "", label: "All databases" }].concat(ws.info.databases) : ws.info.databases
      onCloseRequested: ws.closeRequested()
      onDatabaseChosen: function(db) { ws.switchDatabase(db) }
      Ui.Button { bordered: true; text: "+ Query"; tooltipText: "New SQL query tab (Ctrl+T)"; onClicked: ws.openQuery() }
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
        onActionRequested: function(act, schema, name, kind) { ws.tableAction(act, schema, name, kind) }
        onRefreshRequested: ws.loadTree()
        hasDatabases: ws.info && ws.info.engine !== "sqlite"
        onNewTableRequested: function(schema) { newTable.show(ws.tree.map(function(s) { return s.name }), schema || ws.info.database) }
        onDatabasesRequested: databasesDialog.show(ws.info.databases || [], ws.info.database)
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
                required property string kind
                required property string title
                readonly property var page: { tabStack.count; return ws.page(index) }
                implicitWidth: tabLabel.implicitWidth + closeBtn.implicitWidth + 24
                implicitHeight: Math.round(Style.font.body * 2.4)
                color: index === ws.current ? Color.background : Qt.lighter(Color.background, 1.1)
                Rectangle { visible: index === ws.current; width: parent.width; height: 2; color: Color.accent }
                Text {
                  id: tabLabel
                  x: 12
                  anchors.verticalCenter: parent.verticalCenter
                  text: (page && page.dirty ? "● " : "") + (kind === "query" ? "\uf1c0  " : "") + title
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
            delegate: Loader {
              id: tabLoader
              required property int index
              required property var model
              sourceComponent: model.kind === "query" ? queryTab : tableTab
              Component {
                id: tableTab
                TableTab {
                  schema: tabLoader.model.schema
                  table: tabLoader.model.table
                  engine: ws.info.engine
                  helper: ws.helper
                  sid: ws.info.session
                  onExportRequested: function(target, name) { exportDialog.show(target, name) }
                  active: ws.visible && tabLoader.index === ws.current
                  onNotify: function(text) { ws.toast = text }
                }
              }
              Component {
                id: queryTab
                QueryTab {
                  helper: ws.helper
                  sid: ws.info.session
                  engine: ws.info.engine
                  connId: ws.info.id
                  palette: ws.palette
                  active: ws.visible && tabLoader.index === ws.current
                  onNotify: function(text) { ws.toast = text }
                  onDdlRan: ws.loadTree()
                  onDatabaseReported: function(db) { ws.followDatabase(db) }
                  onExportRequested: function(sql) { exportDialog.show({ sql: sql }, "query") }
                }
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: tabModel.count === 0
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: "Pick a table on the left, or press Ctrl+T for a SQL query"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  Confirm { id: confirm }
  NewTableDialog {
    id: newTable
    helper: ws.helper
    sid: ws.info ? ws.info.session : ""
    engine: ws.info ? ws.info.engine : ""
    onCreated: function(schema, table) { ws.toast = "Created " + table; ws.loadTree(); ws.openTable(schema, table, "structure") }
  }
  DatabasesDialog {
    id: databasesDialog
    helper: ws.helper
    sid: ws.info ? ws.info.session : ""
    engine: ws.info ? ws.info.engine : ""
    onNotify: function(text) { ws.toast = text }
    onChanged: function(list, db) {
      const moved = db !== ws.info.database
      ws.info = Object.assign({}, ws.info, { databases: list, database: db })
      titleBar.resetDatabase()
      if (moved) {
        for (let i = tabModel.count - 1; i >= 0; i--) if (tabModel.get(i).kind === "table") tabModel.remove(i)
        ws.current = tabModel.count ? 0 : -1
      }
      ws.loadTree()
    }
    onOpenRequested: function(db) { ws.switchDatabase(db) }
  }
  ExportDialog {
    id: exportDialog
    helper: ws.helper
    sid: ws.info ? ws.info.session : ""
    folder: ws.downloads
    onNotify: function(text) { ws.toast = text }
  }
  ImportDialog {
    id: importDialog
    helper: ws.helper
    sid: ws.info ? ws.info.session : ""
    folder: ws.downloads
    onNotify: function(text) { ws.toast = text }
    onImported: function(schema, table) { const i = ws.tabIndex(schema, table); if (i >= 0 && ws.page(i)) ws.page(i).reload(true) }
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
