import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

// Create or edit one connection. Passwords are only sent when typed, so an
// untouched field keeps the saved one.
Flickable {
  id: form
  property var helper: null
  property var conn: null          // public connection dict, or null for a new one
  property bool keyring: true
  property string errorText: ""
  property bool busy: false

  signal saved(var conn)
  signal cancelled()
  signal deleted(string id)
  signal duplicated(var conn)

  readonly property var engines: [
    { id: "postgresql", title: "PostgreSQL", port: 5432 }, { id: "mysql", title: "MySQL", port: 3306 },
    { id: "mariadb", title: "MariaDB", port: 3306 }, { id: "sqlite", title: "SQLite", port: 0 },
    { id: "redis", title: "Redis", port: 6379 }, { id: "valkey", title: "Valkey", port: 6379 },
    { id: "mongodb", title: "MongoDB", port: 27017 }]
  readonly property var tags: ["local", "development", "staging", "production"]
  readonly property var sshAuths: ["agent", "key", "password"]
  readonly property string engine: engines[engineBox.currentIndex].id
  readonly property bool isNew: !conn || !conn.id
  readonly property bool fromOmadb: !!conn && conn.source === "omadb"

  contentHeight: body.implicitHeight + 32
  clip: true

  function load(c) {
    conn = c
    errorText = ""
    const v = c || {}
    nameField.setText(v.name || "")
    engineBox.currentIndex = Math.max(0, engines.findIndex(function(e) { return e.id === (v.engine || "postgresql") }))
    hostField.setText(v.host || "127.0.0.1")
    portField.setText(v.port ? String(v.port) : String(engines[engineBox.currentIndex].port))
    userField.setText(v.user || "")
    passField.setText("")
    passField.placeholder = v.has_password ? "Saved (leave empty to keep)" : ""
    dbField.setText(v.database || "")
    pathField.setText(v.path || "")
    tagBox.currentIndex = Math.max(0, tags.indexOf(v.tag || "local"))
    colorField.setText(v.color || "")
    const ssh = v.ssh || {}
    sshSwitch.checked = !!ssh.enabled
    sshHost.setText(ssh.host || "")
    sshPort.setText(String(ssh.port || 22))
    sshUser.setText(ssh.user || "")
    sshAuthBox.currentIndex = Math.max(0, sshAuths.indexOf(ssh.auth || "agent"))
    sshKey.setText(ssh.key_path || "")
    sshPass.setText("")
    sshPass.placeholder = v.has_ssh_password ? "Saved (leave empty to keep)" : ""
    nameField.focusInput()
  }

  function collect() {
    const c = {
      name: nameField.text, engine: engine, host: hostField.text, port: parseInt(portField.text) || 0,
      user: userField.text, database: dbField.text, path: pathField.text,
      tag: tags[tagBox.currentIndex], color: colorField.text || null,
      ssh: sshSwitch.checked ? { enabled: true, host: sshHost.text, port: parseInt(sshPort.text) || 22,
        user: sshUser.text, auth: sshAuths[sshAuthBox.currentIndex], key_path: sshKey.text } : null
    }
    if (!isNew && !fromOmadb) c.id = conn.id
    // OmaDB servers saved as a connection carry their password along.
    if (passField.dirty) c.password = passField.text
    else if (fromOmadb) c.omadb = conn.name
    if (sshPass.dirty) c.ssh_password = sshPass.text
    return c
  }

  function save() {
    if (busy) return
    busy = true
    errorText = ""
    const c = collect()
    const method = c.omadb ? "conn.import_omadb" : "conn.save"
    helper.request(method, c.omadb ? { name: c.omadb, conn: c } : { conn: c }, function(result, error) {
      busy = false
      if (error) { errorText = error.message; return }
      form.saved(result)
    })
  }

  ColumnLayout {
    id: body
    x: 16; y: 16
    width: form.width - 32
    spacing: 12

    Text {
      text: form.fromOmadb ? "OmaDB server · " + form.conn.name : form.isNew ? "New connection" : "Edit connection"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body * 1.4
      font.bold: true
    }

    Field { id: nameField; label: "Name"; Layout.fillWidth: true; placeholder: "My database" }

    RowLayout {
      Layout.fillWidth: true
      spacing: 12
      Column {
        spacing: 4
        Layout.fillWidth: true
        Text { text: "Engine"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        ComboBox {
          id: engineBox
          width: parent.width
          enabled: !form.fromOmadb
          model: form.engines.map(function(e) { return e.title })
          onActivated: portField.setText(String(form.engines[currentIndex].port))
        }
      }
      Column {
        spacing: 4
        Layout.preferredWidth: 160
        Text { text: "Tag"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        ComboBox { id: tagBox; width: parent.width; model: form.tags }
      }
      Field { id: colorField; label: "Color"; Layout.preferredWidth: 110; placeholder: "#rrggbb" }
    }

    Field { id: pathField; label: "Database file"; Layout.fillWidth: true; visible: form.engine === "sqlite"; placeholder: "/path/to/database.db" }

    RowLayout {
      Layout.fillWidth: true
      spacing: 12
      visible: form.engine !== "sqlite"
      Field { id: hostField; label: "Host"; Layout.fillWidth: true; enabled: !form.fromOmadb }
      Field { id: portField; label: "Port"; Layout.preferredWidth: 110; enabled: !form.fromOmadb }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 12
      visible: form.engine !== "sqlite"
      Field { id: userField; label: "User"; Layout.fillWidth: true }
      Field { id: passField; label: "Password"; Layout.fillWidth: true; secret: true }
    }

    Field {
      id: dbField
      Layout.fillWidth: true
      visible: form.engine !== "sqlite"
      label: form.engine === "redis" || form.engine === "valkey" ? "Database index" : "Database"
    }

    Text {
      Layout.fillWidth: true
      visible: !form.keyring && form.engine !== "sqlite"
      text: "No keyring is available: passwords are stored in ~/.config/omatable/connections.json (readable only by you)."
      color: Color.muted
      wrapMode: Text.Wrap
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // ---- SSH tunnel ----
    RowLayout {
      Layout.fillWidth: true
      visible: form.engine !== "sqlite"
      Switch { id: sshSwitch }
      Text { text: "Connect over SSH"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body }
    }

    GridLayout {
      Layout.fillWidth: true
      visible: sshSwitch.checked && form.engine !== "sqlite"
      columns: 2
      columnSpacing: 12
      rowSpacing: 12
      Field { id: sshHost; label: "SSH host"; Layout.fillWidth: true }
      Field { id: sshPort; label: "SSH port"; Layout.preferredWidth: 110 }
      Field { id: sshUser; label: "SSH user"; Layout.fillWidth: true }
      Column {
        spacing: 4
        Layout.preferredWidth: 110
        Text { text: "Auth"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        ComboBox { id: sshAuthBox; width: parent.width; model: form.sshAuths }
      }
      Field { id: sshKey; label: "Key file"; Layout.fillWidth: true; Layout.columnSpan: 2; visible: sshAuthBox.currentIndex === 1; placeholder: "~/.ssh/id_ed25519" }
      Field { id: sshPass; label: "SSH password"; Layout.fillWidth: true; Layout.columnSpan: 2; visible: sshAuthBox.currentIndex === 2; secret: true }
    }

    Text {
      Layout.fillWidth: true
      visible: form.errorText !== ""
      text: form.errorText
      color: Color.urgent
      wrapMode: Text.Wrap
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      Button { text: form.fromOmadb ? "Save as connection" : "Save"; enabled: !form.busy; onClicked: form.save() }
      Button { text: "Cancel"; onClicked: form.cancelled() }
      Item { Layout.fillWidth: true }
      Button {
        text: "Duplicate"
        visible: !form.isNew && !form.fromOmadb
        onClicked: form.helper.request("conn.duplicate", { id: form.conn.id }, function(r, e) {
          if (e) form.errorText = e.message; else form.duplicated(r)
        })
      }
      Button {
        id: deleteButton
        property bool armed: false
        text: armed ? "Click again to delete" : "Delete"
        visible: !form.isNew && !form.fromOmadb
        onClicked: {
          if (!armed) { armed = true; disarm.restart(); return }
          armed = false
          form.helper.request("conn.delete", { id: form.conn.id }, function(r, e) {
            if (e) form.errorText = e.message; else form.deleted(form.conn.id)
          })
        }
        Timer { id: disarm; interval: 3000; onTriggered: deleteButton.armed = false }
      }
    }
  }
}
