import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// Users (PostgreSQL roles, MySQL accounts): list them, create and drop them,
// change passwords and attributes, and grant or revoke privileges. Every
// change shows its SQL (passwords masked) before it runs.
Popup {
  id: dlg

  property var helper: null
  property string sid: ""
  property string engine: ""
  property string database: ""
  property var schemas: []
  property var users: []
  property var privileges: ({})
  property var current: null
  property var grants: []
  property string error: ""
  property string mode: "view"        // view | new
  property var picked: []             // privileges ticked in the grant form
  signal notify(string message)

  readonly property bool mysql: engine === "mysql" || engine === "mariadb"
  readonly property var scopes: mysql ? [{ value: "database", label: "a database" }, { value: "table", label: "a table" }, { value: "global", label: "the whole server" }]
                                      : [{ value: "tables", label: "all tables in a schema" }, { value: "table", label: "a table" },
                                         { value: "schema", label: "a schema" }, { value: "database", label: "the database" }]
  readonly property string scope: scopeBox.value
  readonly property var scopePrivileges: privileges[scope] || []

  function show() { mode = "view"; current = null; grants = []; error = ""; open(); load("") }

  function key(u) { return u.name + (mysql ? "@" + u.host : "") }

  function load(selectKey) {
    helper.request("users.list", { session: sid }, function(r, e) {
      if (e) { error = e.message; return }
      users = r.users
      privileges = r.privileges
      const hit = users.find(function(u) { return key(u) === selectKey })
      if (hit) pick(hit)
      else if (current && !users.find(function(u) { return key(u) === key(current) })) { current = null; grants = [] }
    })
  }

  function pick(u) {
    mode = "view"
    current = u
    error = ""
    pwField.setText("")
    grants = []
    helper.request("users.grants", { session: sid, name: u.name, host: u.host || "" }, function(r, e) {
      if (e) { grants = ["(" + e.message + ")"]; return }
      grants = r.grants
    })
  }

  function spec(extra) {
    return Object.assign({ name: current ? current.name : "", host: current ? current.host : "" }, extra || {})
  }

  // Preview the SQL, confirm, run; then reload and keep the user selected.
  function change(op, s, title, danger, after) {
    error = ""
    helper.request("users.change", { session: sid, op: op, spec: s, preview: true }, function(r, e) {
      if (e) { error = e.message; return }
      confirm.ask({ title: title, detail: r.statements.join(";\n") + ";", confirm: danger ? "Run" : "Apply", danger: !!danger }, function(c) {
        helper.request("users.change", { session: sid, op: op, spec: s, confirmed: true }, function(r2, e2) {
          if (e2) { c.fail(e2.message); return }
          c.done()
          if (after) after()
        })
      })
    })
  }

  function createUser() {
    const s = { name: newName.text.trim(), host: mysql ? (newHost.text.trim() || "%") : "", password: newPw.text }
    if (!mysql) { s.login = newLogin.on; s.createdb = newCreatedb.on; s.superuser = newSuper.on }
    change("create", s, "Create " + s.name + "?", false, function() {
      notify("Created " + s.name)
      newName.setText(""); newPw.setText("")
      load(s.name + (mysql ? "@" + s.host : ""))
    })
  }
  function dropUser() {
    const u = current
    change("drop", spec(), "Drop " + key(u) + "?", true, function() { notify("Dropped " + key(u)); current = null; grants = []; load("") })
  }
  function setPassword() {
    if (!pwField.text) { error = "Type the new password"; return }
    change("alter", spec({ password: pwField.text }), "Change the password of " + key(current) + "?", false,
           function() { notify("Password changed"); pwField.setText("") })
  }
  function setFlag(flag, value) {
    const s = spec()
    s[flag] = value
    change("alter", s, (value ? "Give " : "Take away ") + flag.toUpperCase() + (value ? " to " : " from ") + current.name + "?", flag === "superuser" && value,
           function() { load(key(current)) })
  }
  function grantOrRevoke(revoke) {
    const s = spec({ scope: scope, privileges: picked, database: targetDb.text.trim() || database,
                     schema: targetSchema.value, table: targetTable.text.trim(), future: future.on })
    change(revoke ? "revoke" : "grant", s, (revoke ? "Revoke from " : "Grant to ") + key(current) + "?", revoke,
           function() { notify(revoke ? "Revoked" : "Granted"); picked = []; pick(current) })
  }
  function toggle(p) {
    const i = picked.indexOf(p)
    const copy = picked.slice()
    if (i >= 0) copy.splice(i, 1); else copy.push(p)
    picked = copy
  }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 40 : 900, 1000)
  height: Math.min(parent ? parent.height - 40 : 700, 780)
  padding: 16
  modal: true
  focus: true
  closePolicy: Popup.CloseOnEscape
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  component Label: Text { color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
  component Check: Ui.Button { property bool on: false; bordered: true; selected: on; fontSize: Style.font.bodySmall }

  ColumnLayout {
    anchors.fill: parent
    spacing: 8
    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: dlg.mysql ? "Users" : "Roles and users"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Ui.Button { bordered: true; foreground: Color.accent; text: "+ New user"; onClicked: { dlg.mode = "new"; dlg.current = null; dlg.error = ""; newName.focusInput() } }
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
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 12

      // ---- the list ----
      Rectangle {
        Layout.preferredWidth: 240
        Layout.fillHeight: true
        color: Qt.lighter(Color.background, 1.08)
        radius: 4
        ListView {
          id: userList
          anchors.fill: parent
          anchors.margins: 4
          clip: true
          model: dlg.users
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          delegate: Rectangle {
            id: urow
            required property var modelData
            width: userList.width
            height: Math.round(Style.font.body * 2)
            radius: 3
            color: dlg.current && dlg.key(dlg.current) === dlg.key(modelData) ? Qt.alpha(Color.accent, 0.3)
              : uhover.hovered ? Qt.lighter(Color.background, 1.3) : "transparent"
            HoverHandler { id: uhover }
            TapHandler { onTapped: dlg.pick(urow.modelData) }
            Text {
              x: 8
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 16
              elide: Text.ElideRight
              text: (urow.modelData.superuser ? "★ " : urow.modelData.login === false ? "◇ " : "") + urow.modelData.name
                + (dlg.mysql ? "@" + urow.modelData.host : "")
              color: urow.modelData.login === false ? Color.muted : Color.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      // ---- new user ----
      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: dlg.mode === "new"
        spacing: 10
        Text { text: "New user"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
        RowLayout {
          Layout.fillWidth: true
          Field { id: newName; Layout.fillWidth: true; label: "Name" }
          Field { id: newHost; visible: dlg.mysql; Layout.preferredWidth: 160; label: "Host (% is any)"; placeholder: "%" }
        }
        Field { id: newPw; Layout.fillWidth: true; label: dlg.mysql ? "Password" : "Password (leave empty for a group role)"; secret: true }
        RowLayout {
          visible: !dlg.mysql
          spacing: 6
          Check { id: newLogin; on: true; text: "Can log in"; onClicked: on = !on }
          Check { id: newCreatedb; text: "Create databases"; onClicked: on = !on }
          Check { id: newSuper; text: "Superuser"; foreground: on ? Color.urgent : Color.foreground; onClicked: on = !on }
        }
        RowLayout {
          Item { Layout.fillWidth: true }
          Ui.Button { text: "Cancel"; onClicked: dlg.mode = "view" }
          Ui.Button { bordered: true; foreground: Color.accent; text: "Create"; enabled: newName.text.trim() !== ""; onClicked: dlg.createUser() }
        }
        Item { Layout.fillHeight: true }
      }

      // ---- one user ----
      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: dlg.mode === "view" && dlg.current !== null
        spacing: 10
        RowLayout {
          Layout.fillWidth: true
          Text {
            Layout.fillWidth: true
            text: dlg.current ? dlg.key(dlg.current) : ""
            color: Color.foreground
            font.family: "monospace"
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Ui.Button { text: "Drop…"; foreground: Color.urgent; onClicked: dlg.dropUser() }
        }
        Text {
          visible: !dlg.mysql && dlg.current && dlg.current.member_of && dlg.current.member_of.length > 0
          text: dlg.current && dlg.current.member_of ? "member of " + dlg.current.member_of.join(", ") : ""
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Flow {
          Layout.fillWidth: true
          visible: !dlg.mysql
          spacing: 6
          Repeater {
            model: [{ f: "login", l: "Can log in" }, { f: "createdb", l: "Create databases" }, { f: "createrole", l: "Create roles" },
                    { f: "superuser", l: "Superuser" }]
            delegate: Check {
              required property var modelData
              on: dlg.current ? !!dlg.current[modelData.f] : false
              text: modelData.l
              tooltipText: "Click to " + (on ? "take it away" : "give it")
              onClicked: dlg.setFlag(modelData.f, !on)
            }
          }
        }
        RowLayout {
          Layout.fillWidth: true
          Field { id: pwField; Layout.fillWidth: true; label: "New password"; secret: true }
          Ui.Button { Layout.alignment: Qt.AlignBottom; bordered: true; text: "Change password"; onClicked: dlg.setPassword() }
        }
        Label { text: "Privileges" + (dlg.mysql ? "" : " in " + dlg.database) }
        Rectangle {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.minimumHeight: 80
          color: Qt.lighter(Color.background, 1.08)
          radius: 4
          ListView {
            id: grantList
            anchors.fill: parent
            anchors.margins: 6
            clip: true
            model: dlg.grants
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: Text {
              required property string modelData
              width: grantList.width
              wrapMode: Text.Wrap
              text: modelData
              color: Color.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
            }
            Text { visible: grantList.count === 0; text: "No privileges"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
          }
        }

        // grant / revoke form
        RowLayout {
          Layout.fillWidth: true
          spacing: 6
          Label { text: "On" }
          Ui.Dropdown { id: scopeBox; Layout.preferredWidth: 220; showLabel: false; options: dlg.scopes; value: dlg.scopes[0].value; onChanged: dlg.picked = [] }
          Field { id: targetDb; visible: dlg.mysql && dlg.scope !== "global"; Layout.preferredWidth: 150; label: ""; placeholder: dlg.database || "database" }
          Ui.Dropdown { id: targetSchema; visible: !dlg.mysql && dlg.scope !== "database"; Layout.preferredWidth: 150; showLabel: false
                        options: dlg.schemas; value: dlg.schemas.indexOf("public") >= 0 ? "public" : (dlg.schemas[0] || "") }
          Field { id: targetTable; visible: dlg.scope === "table"; Layout.fillWidth: true; label: ""; placeholder: "table" }
          Item { Layout.fillWidth: dlg.scope !== "table" }
        }
        Flow {
          Layout.fillWidth: true
          spacing: 4
          Repeater {
            model: dlg.scopePrivileges
            delegate: Check {
              required property string modelData
              on: dlg.picked.indexOf(modelData) >= 0
              text: modelData
              onClicked: dlg.toggle(modelData)
            }
          }
        }
        RowLayout {
          Layout.fillWidth: true
          Check { id: future; visible: !dlg.mysql && dlg.scope === "tables"; text: "Also tables created later"; onClicked: on = !on }
          Item { Layout.fillWidth: true }
          Ui.Button { bordered: true; text: "Revoke"; enabled: dlg.picked.length > 0; foreground: Color.urgent; onClicked: dlg.grantOrRevoke(true) }
          Ui.Button { bordered: true; text: "Grant"; enabled: dlg.picked.length > 0; foreground: Color.accent; onClicked: dlg.grantOrRevoke(false) }
        }
      }
      Text {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: dlg.mode === "view" && dlg.current === null
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "Pick a user on the left, or + New user"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
    RowLayout {
      Layout.fillWidth: true
      Item { Layout.fillWidth: true }
      Ui.Button { text: "Close"; onClicked: dlg.close() }
    }
  }

  Confirm { id: confirm }
}
