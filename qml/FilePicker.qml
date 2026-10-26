import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// Pick a file to open, or a folder and name to save as. Lists one folder at a
// time through the helper (file.list); folders first, then matching files.
Popup {
  id: dlg

  property var helper: null
  property string title: ""
  property bool saving: false
  property var extensions: []
  property string confirmText: "Open"
  property string dir: ""
  property string parentDir: ""
  property var entries: []
  property string selected: ""
  property string error: ""
  property var onPick: null      // function(path)

  // opts: { title, save, extensions, folder, name, confirm }
  function pick(opts, done) {
    title = opts.title || (opts.save ? "Save as" : "Open")
    saving = !!opts.save
    extensions = opts.extensions || []
    confirmText = opts.confirm || (saving ? "Save" : "Open")
    selected = ""
    error = ""
    onPick = done
    nameField.setText(opts.name || "")
    open()
    load(opts.folder || dir || "~")
    if (saving) nameField.focusInput()
  }

  function load(path) {
    helper.request("file.list", { path: path, extensions: extensions }, function(r, e) {
      if (e) { error = e.message; return }
      error = ""
      dir = r.dir
      parentDir = r.parent
      entries = r.entries
      selected = ""
      pathField.setText(r.dir)
    })
  }

  function join(name) { return dir === "/" ? "/" + name : dir + "/" + name }

  function choose() {
    let path
    if (saving) {
      const name = nameField.text.trim()
      if (!name) { error = "Type a file name"; return }
      path = name.indexOf("/") >= 0 ? name : join(name)
    } else {
      if (!selected) { error = "Pick a file"; return }
      path = join(selected)
    }
    close()
    if (onPick) onPick(path)
  }

  function size(n) {
    return n < 1024 ? n + " B" : n < 1048576 ? (n / 1024).toFixed(1) + " KB"
      : n < 1073741824 ? (n / 1048576).toFixed(1) + " MB" : (n / 1073741824).toFixed(1) + " GB"
  }

  parent: Overlay.overlay
  anchors.centerIn: parent
  width: Math.min(parent ? parent.width - 60 : 640, 680)
  height: Math.min(parent ? parent.height - 60 : 560, 600)
  padding: 16
  modal: true
  focus: true
  closePolicy: Popup.CloseOnEscape
  background: Rectangle { color: Color.popups.background; border.color: Color.popups.border; border.width: 1 }

  ColumnLayout {
    anchors.fill: parent
    spacing: 8

    Text {
      textFormat: Text.PlainText
      text: dlg.title
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 6
      Ui.Button { text: "↑"; tooltipText: "Parent folder"; enabled: dlg.parentDir !== ""; onClicked: dlg.load(dlg.parentDir) }
      Ui.Button { text: "~"; tooltipText: "Home folder"; onClicked: dlg.load("~") }
      Field {
        id: pathField
        Layout.fillWidth: true
        label: ""
        Keys.onReturnPressed: dlg.load(pathField.text)
        Keys.onEnterPressed: dlg.load(pathField.text)
      }
    }
    Rectangle {
      Layout.fillWidth: true
      Layout.fillHeight: true
      color: Qt.lighter(Color.background, 1.08)
      radius: 4
      ListView {
        id: list
        anchors.fill: parent
        anchors.margins: 4
        clip: true
        model: dlg.entries
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: Rectangle {
          id: row
          required property var modelData
          width: list.width
          height: Math.round(Style.font.body * 2)
          radius: 3
          color: row.modelData.name === dlg.selected ? Qt.alpha(Color.accent, 0.3) : hover.hovered ? Qt.lighter(Color.background, 1.3) : "transparent"
          HoverHandler { id: hover }
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 8
            Text {
              textFormat: Text.PlainText
              text: row.modelData.dir ? "" : ""
              color: row.modelData.dir ? Color.accent : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideMiddle
              text: row.modelData.name
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              textFormat: Text.PlainText
              visible: !row.modelData.dir
              text: dlg.size(row.modelData.size)
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
          TapHandler {
            onTapped: {
              if (row.modelData.dir) { dlg.load(dlg.join(row.modelData.name)); return }
              dlg.selected = row.modelData.name
              if (dlg.saving) nameField.setText(row.modelData.name)
            }
            onDoubleTapped: if (!row.modelData.dir) { dlg.selected = row.modelData.name; if (dlg.saving) nameField.setText(row.modelData.name); dlg.choose() }
          }
        }
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: list.count === 0
          text: dlg.extensions.length ? "No " + dlg.extensions.join(" / ") + " files here" : "Empty folder"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
    Field {
      id: nameField
      Layout.fillWidth: true
      visible: dlg.saving
      label: "File name"
      Keys.onReturnPressed: dlg.choose()
      Keys.onEnterPressed: dlg.choose()
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      visible: dlg.error !== ""
      text: dlg.error
      wrapMode: Text.Wrap
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    RowLayout {
      Layout.fillWidth: true
      Item { Layout.fillWidth: true }
      Ui.Button { text: "Cancel"; onClicked: dlg.close() }
      Ui.Button { bordered: true; foreground: Color.accent; text: dlg.confirmText; onClicked: dlg.choose() }
    }
  }
}
