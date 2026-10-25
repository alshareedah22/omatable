import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui as Ui

// A MongoDB connection: collections on the left; on the right the selected
// collection's documents (grid or JSON), found with a filter or an
// aggregation pipeline, its indexes, and a command console below.
Item {
  id: mb

  property var helper: null
  property var info: null
  property string toast: ""
  property var tree: ({ tables: [], views: [] })
  property bool treeLoading: false
  property string search: ""
  property string collection: ""
  property bool isView: false
  property string mode: "find"          // find | aggregate
  property string page: "documents"     // documents | json | indexes
  property int skip: 0
  property int limit: 100
  property var count: null
  property bool running: false
  property string error: ""
  property var indexes: []
  property bool consoleOpen: false
  property bool uniqueIndex: false
  readonly property bool dirty: false
  readonly property string sid: info ? info.session : ""
  signal closeRequested()

  function loadTree() {
    treeLoading = true
    helper.request("schema.tree", { session: sid }, function(r, e) {
      treeLoading = false
      if (e) { toast = e.message; return }
      tree = r.schemas[0] || { tables: [], views: [] }
      if (collection && tree.tables.indexOf(collection) < 0 && tree.views.indexOf(collection) < 0) collection = ""
    })
  }

  function open(name, view) {
    collection = name
    isView = view
    filterField.text = ""
    sortField.text = ""
    projField.text = ""
    docsModel.sort = []
    skip = 0
    count = null
    if (page === "indexes" && view) page = "documents"
    run(true)
  }

  function run(reset) {
    if (!collection) return
    if (reset) skip = 0
    if (page === "indexes" && mode === "aggregate") page = "documents"
    running = true
    error = ""
    const asked = collection
    const done = function(r, e) {
      if (asked !== collection) return
      running = false
      if (e) { error = e.message; return }
      docsModel.result = r
    }
    if (mode === "find") {
      helper.request("mongo.find", { session: sid, collection: collection, filter: filterField.text, sort: sortField.text,
                                     projection: projField.text, skip: skip, limit: limit }, done)
      if (reset) {
        count = null
        helper.request("mongo.count", { session: sid, collection: collection, filter: filterField.text }, function(r, e) {
          if (asked === collection && !e) count = r
        })
      }
    } else {
      count = null
      helper.request("mongo.aggregate", { session: sid, collection: collection, pipeline: pipeArea.text, limit: limit }, done)
    }
    if (page === "indexes") loadIndexes()
  }

  function quoteField(name) { return /^[A-Za-z_$][\w$]*$/.test(name) ? name : JSON.stringify(name) }

  function readOnlyNote() { toast = isView ? collection + " is a view; views are read-only" : "Aggregation results are read-only; switch to Find to edit" }
  readonly property bool canWrite: collection !== "" && !isView && mode === "find"

  function editDoc(r) {
    if (!canWrite) { readOnlyNote(); return }
    const id = docsModel.result.ids[r]
    if (id === null) { toast = "This document has no _id, so it cannot be edited"; return }
    jsonEditor.edit({ title: "Edit document in " + collection, text: docsModel.result.docs[r], confirm: "Save",
                      hint: "The whole document is replaced. The _id cannot change." }, function(text, dlg) {
      helper.request("mongo.update", { session: sid, collection: collection, id: id, text: text }, function(res, e) {
        if (e) { dlg.fail(e.message); return }
        dlg.done()
        toast = res.modified ? "Saved" : "No changes"
        run(false)
      })
    })
  }

  function insertDoc(text) {
    if (!canWrite) { readOnlyNote(); return }
    jsonEditor.edit({ title: "Insert into " + collection, text: text || "{\n  \n}", confirm: "Insert",
                      hint: "One document, or a list of documents. Leave out _id to get a new ObjectId." }, function(t, dlg) {
      helper.request("mongo.insert", { session: sid, collection: collection, text: t }, function(res, e) {
        if (e) { dlg.fail(e.message); return }
        dlg.done()
        toast = "Inserted " + res.inserted + (res.inserted === 1 ? " document" : " documents")
        run(true)
      })
    })
  }

  function duplicateDoc(r) {
    let text = docsModel.result.docs[r]
    try {
      const doc = JSON.parse(text)
      delete doc._id
      text = JSON.stringify(doc, null, 2)
    } catch (err) {}
    insertDoc(text)
  }

  function deleteDoc(r) {
    if (!canWrite) { readOnlyNote(); return }
    const id = docsModel.result.ids[r]
    if (id === null) { toast = "This document has no _id, so it cannot be deleted here"; return }
    const label = docsModel.rows[r][0]
    confirm.ask({ title: "Delete this document?", text: "_id " + label + " in " + collection + ". This cannot be undone.",
                  confirm: "Delete", danger: true }, function(dlg) {
      helper.request("mongo.delete", { session: sid, collection: collection, ids: [id] }, function(res, e) {
        if (e) { dlg.fail(e.message); return }
        dlg.done()
        toast = res.deleted ? "Deleted" : "It was already gone"
        run(false)
        if (count) count = Object.assign({}, count, { count: Math.max(0, count.count - res.deleted) })
      })
    })
  }

  function loadIndexes() {
    if (!collection || isView) { indexes = []; return }
    helper.request("mongo.indexes", { session: sid, collection: collection }, function(r, e) {
      if (e) { toast = e.message; return }
      indexes = r.indexes
    })
  }

  function createIndex() {
    helper.request("mongo.create_index", { session: sid, collection: collection, keys: ixKeys.text, unique: uniqueIndex, name: ixName.text.trim() }, function(r, e) {
      if (e) { toast = e.message; return }
      toast = "Created index " + r.name
      ixKeys.text = ""
      ixName.text = ""
      loadIndexes()
    })
  }

  function dropIndex(name) {
    confirm.ask({ title: "Drop index " + name + "?", text: "Queries that use it get slower; unique rules it enforces stop applying.",
                  confirm: "Drop index", danger: true }, function(dlg) {
      helper.request("mongo.drop_index", { session: sid, collection: collection, name: name }, function(r, e) {
        if (e) { dlg.fail(e.message); return }
        dlg.done()
        loadIndexes()
      })
    })
  }

  function dropCollection(name, view) {
    confirm.ask({ title: "Drop " + (view ? "view " : "collection ") + name + "?",
                  text: view ? "The view definition is deleted; its source data stays." : "Every document and index in " + name + " is deleted. This cannot be undone.",
                  confirm: view ? "Drop view" : "Drop collection", danger: true }, function(dlg) {
      helper.request("mongo.drop_collection", { session: sid, name: name }, function(r, e) {
        if (e) { dlg.fail(e.message); return }
        dlg.done()
        if (collection === name) { collection = ""; docsModel.result = null }
        toast = "Dropped " + name
        loadTree()
      })
    })
  }

  function switchDatabase(db) {
    helper.request("session.use", { session: sid, database: db }, function(r, e) {
      if (e) { toast = e.message; titleBar.resetDatabase(); return }
      info = Object.assign({}, info, { database: r.database })
      collection = ""
      docsModel.result = null
      loadTree()
    })
  }

  Component.onCompleted: loadTree()

  Shortcut { sequence: "Ctrl+`"; enabled: mb.visible; onActivated: mb.consoleOpen = !mb.consoleOpen }
  Shortcut { sequence: "Ctrl+R"; enabled: mb.visible && mb.collection !== ""; onActivated: mb.run(false) }
  Shortcut { sequence: "Ctrl+I"; enabled: mb.visible && mb.collection !== ""; onActivated: mb.insertDoc("") }
  Shortcut { sequence: "Ctrl+F"; enabled: mb.visible && mb.collection !== ""; onActivated: (mb.mode === "find" ? filterField : pipeArea).forceActiveFocus() }

  MongoModel {
    id: docsModel
    loading: mb.running
    error: mb.error
    onNotify: function(text) { mb.toast = text }
    onEditRequested: function(r) { mb.editDoc(r) }
    onDuplicateRequested: function(r) { if (mb.canWrite) mb.duplicateDoc(r); else mb.readOnlyNote() }
    onInsertRequested: mb.insertDoc("")
    onDeleteRequested: function(r) { mb.deleteDoc(r) }
    onSortRequested: function(s) {
      if (mb.mode !== "find") { mb.toast = "Sort inside the pipeline with {$sort: {...}}"; sort = []; return }
      sortField.text = "{" + mb.quoteField(s[0].column) + ": " + (s[0].desc ? -1 : 1) + "}"
      mb.run(true)
    }
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    TitleBar {
      id: titleBar
      Layout.fillWidth: true
      info: mb.info
      showDatabases: true
      databaseOptions: mb.info ? mb.info.databases : []
      onCloseRequested: mb.closeRequested()
      onDatabaseChosen: function(db) { mb.switchDatabase(db) }
      Ui.Button { bordered: mb.consoleOpen; text: "Console"; tooltipText: "Run database commands (Ctrl+`)"; onClicked: mb.consoleOpen = !mb.consoleOpen }
    }

    SplitView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      orientation: Qt.Vertical

      RowLayout {
        SplitView.fillHeight: true
        spacing: 0

        // ---- collections ----
        Rectangle {
          Layout.preferredWidth: 260
          Layout.fillHeight: true
          color: Qt.lighter(Color.background, 1.05)
          ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6
            RowLayout {
              Layout.fillWidth: true
              spacing: 4
              Ui.TextField {
                Layout.fillWidth: true
                placeholderText: "Search collections"
                font.family: Style.font.family
                onTextChanged: mb.search = text.toLowerCase()
              }
              Ui.Button { text: "+"; tooltipText: "New collection"; onClicked: { newColl.err = ""; newCollName.setText(""); newColl.open() } }
              Ui.Button { text: ""; tooltipText: "Reload"; onClicked: mb.loadTree() }
            }
            ListView {
              id: collList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              model: {
                const out = []
                const f = mb.search
                const tables = mb.tree.tables.filter(function(n) { return !f || n.toLowerCase().indexOf(f) >= 0 })
                const views = mb.tree.views.filter(function(n) { return !f || n.toLowerCase().indexOf(f) >= 0 })
                if (tables.length) out.push({ head: "Collections  " + tables.length })
                for (const n of tables) out.push({ name: n, view: false })
                if (views.length) out.push({ head: "Views  " + views.length })
                for (const n of views) out.push({ name: n, view: true })
                return out
              }
              delegate: Rectangle {
                id: collRow
                required property var modelData
                width: collList.width
                height: Math.round(Style.font.body * 1.9)
                radius: 4
                color: modelData.name === mb.collection ? Qt.lighter(Color.background, 1.5)
                  : collHover.hovered && !modelData.head ? Qt.lighter(Color.background, 1.25) : "transparent"
                HoverHandler { id: collHover }
                Text {
                  x: 6
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 12
                  elide: Text.ElideRight
                  text: collRow.modelData.head ? collRow.modelData.head : (collRow.modelData.view ? "  " : "  ") + collRow.modelData.name
                  color: collRow.modelData.head ? Color.muted : Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: collRow.modelData.head ? Style.font.bodySmall : Style.font.body
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: !collRow.modelData.head
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onClicked: function(mouse) {
                    const d = collRow.modelData
                    if (mouse.button === Qt.RightButton) {
                      collMenu.item = d
                      const p = mapToItem(mb, mouse.x, mouse.y)
                      collMenu.x = Math.min(p.x, mb.width - collMenu.width - 4)
                      collMenu.y = Math.min(p.y, mb.height - collMenu.implicitHeight - 4)
                      collMenu.open()
                    } else mb.open(d.name, d.view)
                  }
                }
              }
              Text {
                y: 8
                width: collList.width
                visible: collList.count === 0
                wrapMode: Text.Wrap
                text: mb.treeLoading ? "Loading…" : mb.search ? "No matches" : "No collections in " + (mb.info ? mb.info.database : "") + ". Press + to create one."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Qt.lighter(Color.background, 1.5) }

        // ---- documents ----
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          Text {
            anchors.centerIn: parent
            visible: mb.collection === ""
            text: "Pick a collection on the left"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          ColumnLayout {
            anchors.fill: parent
            visible: mb.collection !== ""
            spacing: 0

            Rectangle {
              Layout.fillWidth: true
              implicitHeight: bar.implicitHeight + 16
              color: Qt.lighter(Color.background, 1.08)
              ColumnLayout {
                id: bar
                x: 8
                y: 8
                width: parent.width - 16
                spacing: 6
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6
                  Ui.Button { bordered: mb.mode === "find"; text: "Find"; onClicked: { mb.mode = "find"; mb.run(true) } }
                  Ui.Button { bordered: mb.mode === "aggregate"; text: "Aggregate"; onClicked: { mb.mode = "aggregate"; if (pipeArea.text.trim() === "") pipeArea.text = "[\n  {$match: {}}\n]"; pipeArea.forceActiveFocus() } }
                  Ui.TextField {
                    id: filterField
                    visible: mb.mode === "find"
                    Layout.fillWidth: true
                    Layout.preferredWidth: 320
                    Layout.minimumWidth: 120
                    placeholderText: "Filter, e.g. {age: {$gt: 30}}"
                    font.family: "monospace"
                    Keys.onReturnPressed: mb.run(true)
                    Keys.onEnterPressed: mb.run(true)
                  }
                  Ui.TextField {
                    id: sortField
                    visible: mb.mode === "find"
                    Layout.fillWidth: true
                    Layout.preferredWidth: 130
                    Layout.minimumWidth: 70
                    Layout.maximumWidth: 220
                    placeholderText: "Sort {_id: -1}"
                    font.family: "monospace"
                    onTextEdited: docsModel.sort = []
                    Keys.onReturnPressed: mb.run(true)
                    Keys.onEnterPressed: mb.run(true)
                  }
                  Ui.TextField {
                    id: projField
                    visible: mb.mode === "find"
                    Layout.fillWidth: true
                    Layout.preferredWidth: 130
                    Layout.minimumWidth: 70
                    Layout.maximumWidth: 220
                    placeholderText: "Fields {name: 1}"
                    font.family: "monospace"
                    Keys.onReturnPressed: mb.run(true)
                    Keys.onEnterPressed: mb.run(true)
                  }
                  Item { visible: mb.mode !== "find"; Layout.fillWidth: true }
                  Ui.Button { bordered: true; foreground: Color.accent; text: mb.running ? "Running…" : "Run"; tooltipText: "Run (Enter, Ctrl+R)"; enabled: !mb.running; onClicked: mb.run(true) }
                }
                ScrollView {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.round(Style.font.body * 6)
                  visible: mb.mode === "aggregate"
                  TextArea {
                    id: pipeArea
                    placeholderText: "[{$match: {...}}, {$group: {...}}]"
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    color: Color.foreground
                    placeholderTextColor: Color.muted
                    font.family: "monospace"
                    font.pixelSize: Style.font.body
                    background: Rectangle { color: Qt.lighter(Color.background, 1.2); border.color: pipeArea.activeFocus ? Color.accent : Qt.lighter(Color.background, 1.6); radius: 4 }
                    Keys.onPressed: function(event) {
                      if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { mb.run(true); event.accepted = true }
                    }
                  }
                }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6
                  Ui.Button { bordered: mb.page === "documents"; text: "Documents"; onClicked: mb.page = "documents" }
                  Ui.Button { bordered: mb.page === "json"; text: "JSON"; onClicked: mb.page = "json" }
                  Ui.Button { visible: !mb.isView; bordered: mb.page === "indexes"; text: "Indexes"; onClicked: { mb.page = "indexes"; mb.loadIndexes() } }
                  Item { Layout.fillWidth: true }
                  Ui.Button { visible: mb.canWrite; text: "+ Insert"; tooltipText: "Insert documents (Ctrl+I)"; onClicked: mb.insertDoc("") }
                  Ui.Button { visible: mb.canWrite && mb.page !== "indexes"; text: "Edit"; enabled: docsModel.selRow >= 0; onClicked: mb.editDoc(docsModel.selRow) }
                  Ui.Button { visible: mb.canWrite && mb.page !== "indexes"; text: "Delete"; foreground: Color.urgent; enabled: docsModel.selRow >= 0; onClicked: mb.deleteDoc(docsModel.selRow) }
                }
              }
            }

            Text {
              Layout.fillWidth: true
              Layout.margins: 8
              visible: mb.error !== ""
              text: mb.error
              wrapMode: Text.Wrap
              color: Color.urgent
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
            }

            DataGrid {
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: mb.page === "documents"
              tab: docsModel
            }

            ListView {
              id: jsonList
              Layout.fillWidth: true
              Layout.fillHeight: true
              visible: mb.page === "json"
              clip: true
              spacing: 6
              model: docsModel.result ? docsModel.result.docs : []
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              delegate: Rectangle {
                id: docItem
                required property var modelData
                required property int index
                width: jsonList.width - 16
                x: 8
                height: docText.implicitHeight + 16
                radius: 4
                color: index === docsModel.selRow ? Qt.lighter(Color.background, 1.3) : Qt.lighter(Color.background, 1.08)
                border.color: index === docsModel.selRow ? Color.accent : "transparent"
                TextEdit {
                  id: docText
                  x: 8
                  y: 8
                  width: parent.width - 16
                  readOnly: true
                  selectByMouse: true
                  wrapMode: TextEdit.Wrap
                  text: docItem.modelData
                  color: Color.foreground
                  font.family: "monospace"
                  font.pixelSize: Style.font.bodySmall
                }
                TapHandler {
                  onTapped: docsModel.select(docItem.index, 0)
                  onDoubleTapped: mb.editDoc(docItem.index)
                }
              }
              Text {
                y: 8
                x: 8
                visible: jsonList.count === 0
                text: mb.running ? "Loading…" : "No documents"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.margins: 8
              visible: mb.page === "indexes"
              spacing: 6
              ListView {
                id: ixList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: mb.indexes
                delegate: Rectangle {
                  id: ixRow
                  required property var modelData
                  required property int index
                  width: ixList.width
                  height: Math.round(Style.font.body * 2.2)
                  color: index % 2 ? Qt.lighter(Color.background, 1.05) : "transparent"
                  RowLayout {
                    x: 8
                    width: parent.width - 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Text { Layout.preferredWidth: 200; text: ixRow.modelData.name; elide: Text.ElideRight; color: Color.foreground; font.family: "monospace"; font.pixelSize: Style.font.bodySmall }
                    Text { Layout.fillWidth: true; text: ixRow.modelData.keys; elide: Text.ElideRight; color: Color.foreground; font.family: "monospace"; font.pixelSize: Style.font.bodySmall }
                    Text {
                      text: [ixRow.modelData.unique ? "unique" : "", ixRow.modelData.sparse ? "sparse" : "",
                             ixRow.modelData.ttl !== null && ixRow.modelData.ttl !== undefined ? "TTL " + ixRow.modelData.ttl + " s" : "",
                             ixRow.modelData.partial ? "partial" : ""].filter(function(x) { return x }).join(" · ")
                      color: Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                    Ui.Button { visible: ixRow.modelData.name !== "_id_"; text: "Drop"; foreground: Color.urgent; fontSize: Style.font.bodySmall; onClicked: mb.dropIndex(ixRow.modelData.name) }
                  }
                }
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Ui.TextField { id: ixKeys; Layout.fillWidth: true; placeholderText: "Keys, e.g. {email: 1} or {name: 1, age: -1}"; font.family: "monospace"; Keys.onReturnPressed: mb.createIndex() }
                Ui.TextField { id: ixName; Layout.preferredWidth: 160; placeholderText: "Name (optional)"; font.family: Style.font.family }
                Ui.Button { bordered: mb.uniqueIndex; text: mb.uniqueIndex ? "Unique" : "Not unique"; onClicked: mb.uniqueIndex = !mb.uniqueIndex }
                Ui.Button { bordered: true; foreground: Color.accent; text: "Create index"; enabled: ixKeys.text.trim() !== ""; onClicked: mb.createIndex() }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              visible: mb.page !== "indexes"
              implicitHeight: pageRow.implicitHeight + 8
              color: Qt.lighter(Color.background, 1.08)
              RowLayout {
                id: pageRow
                x: 8
                width: parent.width - 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Text {
                  Layout.fillWidth: true
                  text: {
                    const n = docsModel.rowCount
                    const range = n ? (mb.skip + 1).toLocaleString(Qt.locale(), "f", 0) + "–" + (mb.skip + n).toLocaleString(Qt.locale(), "f", 0) : "0"
                    return range + (mb.count ? " of " + (mb.count.estimated ? "~" : "") + mb.count.count.toLocaleString(Qt.locale(), "f", 0) : "")
                      + (docsModel.result ? "  ·  " + docsModel.result.ms + " ms" : "")
                  }
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Ui.Button { visible: mb.mode === "find"; text: "‹"; enabled: mb.skip > 0 && !mb.running; onClicked: { mb.skip = Math.max(0, mb.skip - mb.limit); mb.run(false) } }
                Ui.Button { visible: mb.mode === "find"; text: "›"; enabled: docsModel.rowCount >= mb.limit && !mb.running; onClicked: { mb.skip += mb.limit; mb.run(false) } }
                Text { text: "per page"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
                Ui.Dropdown {
                  Layout.preferredWidth: 90
                  showLabel: false
                  options: [{ value: "50", label: "50" }, { value: "100", label: "100" }, { value: "500", label: "500" }, { value: "1000", label: "1000" }]
                  value: String(mb.limit)
                  onChanged: function(v) { mb.limit = parseInt(v); mb.run(true) }
                }
              }
            }
          }
        }
      }

      Console {
        visible: mb.consoleOpen
        SplitView.preferredHeight: 260
        SplitView.minimumHeight: 140
        helper: mb.helper
        sid: mb.sid
        connId: mb.info ? mb.info.id : ""
        method: "mongo.run"
        multiline: true
        placeholder: "{dbStats: 1}   ·   Ctrl+Enter runs, Ctrl+Up/Down for history"
        formatter: function(r) { return r.reply }
        onCloseRequested: mb.consoleOpen = false
        onRan: mb.loadTree()
      }
    }
  }

  Popup {
    id: collMenu
    property var item: null
    padding: 4
    width: 190
    background: Rectangle { color: Color.menu.background; border.color: Color.menu.border; border.width: 1 }
    Column {
      width: parent.width
      Repeater {
        model: [{ act: "open", label: "Open" }, { act: "drop", label: "Drop…", danger: true }, { act: "copy", label: "Copy name" }]
        delegate: Ui.Button {
          required property var modelData
          width: collMenu.width - 8
          leftAlign: true
          text: modelData.label
          foreground: modelData.danger ? Color.urgent : Color.foreground
          onClicked: {
            const d = collMenu.item
            collMenu.close()
            if (modelData.act === "open") mb.open(d.name, d.view)
            else if (modelData.act === "drop") mb.dropCollection(d.name, d.view)
            else { Quickshell.execDetached(["wl-copy", "--", d.name]); mb.toast = "Copied" }
          }
        }
      }
    }
  }

  Popup {
    id: newColl
    property string err: ""
    function create() {
      helper.request("mongo.create_collection", { session: mb.sid, name: newCollName.text }, function(r, e) {
        if (e) { newColl.err = e.message; return }
        newColl.close()
        mb.loadTree()
        mb.open(newCollName.text, false)
        mb.toast = "Created " + newCollName.text
      })
    }
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(parent ? parent.width - 80 : 480, 440)
    padding: 16
    modal: true
    focus: true
    background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }
    onOpened: newCollName.focusInput()
    ColumnLayout {
      anchors.fill: parent
      spacing: 10
      Field { id: newCollName; Layout.fillWidth: true; label: "New collection in " + (mb.info ? mb.info.database : ""); Keys.onReturnPressed: newColl.create() }
      Text { Layout.fillWidth: true; visible: newColl.err !== ""; text: newColl.err; wrapMode: Text.Wrap; color: Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      RowLayout {
        Layout.fillWidth: true
        Item { Layout.fillWidth: true }
        Ui.Button { text: "Cancel"; onClicked: newColl.close() }
        Ui.Button { bordered: true; foreground: Color.accent; text: "Create"; enabled: newCollName.text.trim() !== ""; onClicked: newColl.create() }
      }
    }
  }

  Confirm { id: confirm }
  JsonEditor { id: jsonEditor }
  Toast { message: mb.toast; onExpired: mb.toast = "" }
}
