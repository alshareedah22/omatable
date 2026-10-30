import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// An open session: title strip, schema sidebar and one tab per table or query.
Item {
  id: ws

  property var helper: null
  property var info: null          // session.open result
  property var tree: []
  property var catalog: []         // tables and columns for the SQL autocomplete
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
    helper.request("schema.catalog", { session: info.session }, function(r, e) { catalog = e ? [] : r.tables })
  }

  function openTable(schema, table, view) {
    let i = 0
    for (; i < tabModel.count; i++) {
      const t = tabModel.get(i)
      if (t.kind === "table" && t.schema === schema && t.table === table) break
    }
    if (i === tabModel.count) tabModel.append({ kind: "table", schema: schema, table: table, title: table, sql: "" })
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
    if (act === "definition" || act === "dropfn") { objectAction(act, schema, name, kind); return }
    if (act === "newview") { objectAction("new", schema, "", "view"); return }
    if (act === "newfunction") { objectAction("new", schema, "", "function"); return }
    if (act === "newtrigger") { objectAction("new", schema, name, "trigger"); return }
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

  function stamp() {
    const d = new Date()
    const p = function(n) { return (n < 10 ? "0" : "") + n }
    return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + "-" + p(d.getHours()) + p(d.getMinutes())
  }

  function backup(overwrite, path) {
    const db = info.database
    if (!db && info.engine !== "sqlite") { toast = "Pick a database in the Database list first"; return }
    if (!path) {
      const base = (info.engine === "sqlite" ? info.name : db).replace(/[^A-Za-z0-9_.-]+/g, "_")
      picker.pick({ title: "Back up " + (db || info.name), save: true, folder: downloads, confirm: "Back up",
                    extensions: info.engine === "sqlite" ? [".db", ".sqlite"] : [".sql"],
                    name: base + "-" + stamp() + (info.engine === "sqlite" ? ".db" : ".sql") }, function(p) { backup(false, p) })
      return
    }
    busy.start("Backing up " + (db || info.name) + " to " + path.split("/").pop() + "…",
               function() { helper.request("query.cancel", { session: info.session }) })
    helper.request("db.backup", { session: info.session, path: path, database: db || null, overwrite: overwrite }, function(r, e) {
      busy.finish()
      if (e && e.code === "exists") {
        confirm.ask({ title: "Replace " + path.split("/").pop() + "?", text: "A file with that name already exists.",
                      confirm: "Replace", danger: true }, function(dlg) { dlg.done(); backup(true, path) })
        return
      }
      if (e) { if (e.code !== "cancelled") toast = e.message; else toast = "Backup cancelled"; return }
      toast = "Backed up " + (r.database || db) + " to " + r.path + " (" + picker.size(r.bytes) + ")"
    })
  }

  function restore() {
    const db = info.database
    if (!db) { toast = "Pick a database in the Database list first"; return }
    picker.pick({ title: "Restore into " + db, folder: downloads, confirm: "Restore",
                  extensions: info.engine === "postgresql" ? [".sql", ".dump", ".backup"] : [".sql"] }, function(path) {
      const name = path.split("/").pop()
      confirm.ask({ title: "Restore " + name + " into " + db + "?",
                    text: "Every statement in the file runs against " + db + ". Tables the file creates must not exist yet"
                      + (info.engine === "postgresql" ? "; if anything fails, nothing is changed." : "."),
                    confirm: "Restore", danger: true }, function(dlg) {
        dlg.done()
        busy.start("Restoring " + name + " into " + db + "…", function() { helper.request("query.cancel", { session: info.session }) })
        helper.request("db.restore", { session: info.session, path: path, database: db, confirmed: true }, function(r, e) {
          busy.finish()
          if (e) { toast = e.code === "cancelled" ? "Restore cancelled" : e.message; return }
          toast = "Restored " + name + " into " + db + " in " + (r.ms / 1000).toFixed(1) + " s"
          loadTree()
        })
      })
    })
  }

  function openDiagram() {
    for (let i = 0; i < tabModel.count; i++) if (tabModel.get(i).kind === "diagram") { current = i; return }
    tabModel.append({ kind: "diagram", schema: "", table: "", title: "Diagram", sql: "" })
    current = tabModel.count - 1
  }

  function openQuery(sql, title) {
    queryCount++
    tabModel.append({ kind: "query", schema: "", table: "", title: title || "Query " + queryCount, sql: sql || "" })
    current = tabModel.count - 1
  }

  // Views, functions, triggers: definitions and templates open in a query tab to edit and run.
  function defaultSchema() {
    const names = tree.map(function(s) { return s.name })
    return names.indexOf("public") >= 0 ? "public" : info.database && names.indexOf(info.database) >= 0 ? info.database : (names[0] || "")
  }

  function objectAction(act, schema, name, kind) {
    schema = schema || defaultSchema()
    if (act === "definition") {
      helper.request("schema.definition", { session: info.session, schema: schema, name: name, kind: kind }, function(r, e) {
        if (e) { toast = e.message; return }
        openQuery(r.sql, name)
      })
    } else if (act === "new") {
      helper.request("schema.template", { session: info.session, schema: schema, kind: kind, table: name || null }, function(r, e) {
        if (e) { toast = e.message; return }
        openQuery(r.sql, "new " + kind)
      })
    } else if (act === "dropfn") {
      confirm.ask({ title: "Drop the function " + name + "?", text: "Anything that calls it stops working.", confirm: "Drop function", danger: true }, function(dlg) {
        helper.request("schema.drop_object", { session: info.session, schema: schema, name: name, kind: "function", confirmed: true }, function(r, e) {
          if (e) { dlg.fail(e.message); return }
          dlg.done()
          toast = "Dropped " + name
          loadTree()
        })
      })
    }
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
      Ui.Button {
        id: serverBtn
        bordered: true
        text: "Server ▾"
        tooltipText: "Databases, running queries, users, backup"
        onClicked: {
          const p = serverBtn.mapToItem(ws, 0, serverBtn.height + 2)
          serverMenu.x = Math.min(p.x, ws.width - serverMenu.width - 4)
          serverMenu.y = p.y
          serverMenu.open()
        }
      }
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
        functions: ws.info && ws.info.engine !== "sqlite"
        onNewTableRequested: function(schema) { newTable.show(ws.tree.map(function(s) { return s.name }), schema || ws.info.database) }
      }
      Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Qt.lighter(Commons.Color.background, 1.5) }

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
                color: index === ws.current ? Commons.Color.background : Qt.lighter(Commons.Color.background, 1.1)
                Rectangle { visible: index === ws.current; width: parent.width; height: 2; color: Commons.Color.accent }
                Text {
                  id: tabLabel
                  textFormat: Text.PlainText
                  x: 12
                  anchors.verticalCenter: parent.verticalCenter
                  text: (page && page.dirty ? "● " : "") + (kind === "query" ? "\uf1c0  " : "") + title
                  color: index === ws.current ? Commons.Color.foreground : Commons.Color.muted
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
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.lighter(Commons.Color.background, 1.4) }
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
              sourceComponent: model.kind === "query" ? queryTab : model.kind === "diagram" ? diagramTab : tableTab
              Component {
                id: diagramTab
                DiagramTab {
                  helper: ws.helper
                  sid: ws.info.session
                  schemas: ws.tree.length > 1 ? [{ value: "", label: "All schemas" }].concat(ws.tree.map(function(s) { return s.name })) : []
                  schema: ws.tree.length > 1 ? ws.defaultSchema() : ""
                  active: ws.visible && tabLoader.index === ws.current
                  onOpenTable: function(schema, table) { ws.openTable(schema, table) }
                  onNotify: function(text) { ws.toast = text }
                }
              }
              Component {
                id: tableTab
                TableTab {
                  schema: tabLoader.model.schema
                  table: tabLoader.model.table
                  engine: ws.info.engine
                  helper: ws.helper
                  sid: ws.info.session
                  onExportRequested: function(target, name) { exportDialog.show(target, name) }
                  onSqlRequested: function(sql, title) { ws.openQuery(sql, title) }
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
                  catalog: ws.catalog
                  folder: ws.downloads
                  initialText: tabLoader.model.sql || ""
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
          textFormat: Text.PlainText
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: tabModel.count === 0
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: "Pick a table on the left, or press Ctrl+T for a SQL query"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  Confirm { id: confirm }
  FilePicker { id: picker; helper: ws.helper }
  ProcessesDialog { id: processes; helper: ws.helper; sid: ws.info ? ws.info.session : ""; engine: ws.info ? ws.info.engine : ""; onNotify: function(m) { ws.toast = m } }
  UsersDialog {
    id: usersDialog
    helper: ws.helper
    sid: ws.info ? ws.info.session : ""
    engine: ws.info ? ws.info.engine : ""
    database: ws.info ? ws.info.database : ""
    schemas: ws.tree.map(function(s) { return s.name })
    onNotify: function(m) { ws.toast = m }
  }

  Popup {
    id: serverMenu
    readonly property bool sqlite: ws.info && ws.info.engine === "sqlite"
    padding: 4
    width: 220
    background: Rectangle { color: Commons.Color.menu.background; border.color: Commons.Color.menu.border; border.width: 1 }
    Column {
      width: parent.width
      Repeater {
        model: serverMenu.sqlite ? [{ act: "diagram", label: "Table diagram" }, { act: "backup", label: "Back up database…" }]
          : [{ act: "diagram", label: "Table diagram" }, { act: "databases", label: "Databases…" }, { act: "processes", label: "Running queries…" },
             { act: "users", label: "Users and privileges…" }, { act: "backup", label: "Back up database…" },
             { act: "restore", label: "Restore from file…" }]
        delegate: Ui.Button {
          required property var modelData
          width: serverMenu.width - 8
          leftAlign: true
          text: modelData.label
          onClicked: {
            serverMenu.close()
            const a = modelData.act
            if (a === "diagram") ws.openDiagram()
            else if (a === "databases") databasesDialog.show(ws.info.databases || [], ws.info.database)
            else if (a === "processes") processes.show()
            else if (a === "users") usersDialog.show()
            else if (a === "backup") ws.backup(false, "")
            else ws.restore()
          }
        }
      }
    }
  }
  Busy { id: busy }
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
    color: Commons.Color.popups.background
    border.color: Commons.Color.popups.border
    Text {
      id: toastText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      width: parent.width - 32
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: ws.toast
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }
}
