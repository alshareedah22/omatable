import QtQuick
import QtQuick.Controls
import qs.Commons
import "SqlHighlight.js" as Hl
import "Complete.js" as Cmp

// SQL editor: a plain, transparent TextEdit for typing over a rich-text copy
// that shows the colours. Both use the same font, padding and no wrapping,
// so every glyph of the colour layer sits under the one being edited.
FocusScope {
  id: ed

  property alias text: input.text
  property string engine: ""
  property var palette: ({})
  property var catalog: []          // tables with columns, for autocomplete
  property alias cursorPosition: input.cursorPosition
  readonly property alias selectionStart: input.selectionStart
  readonly property alias selectionEnd: input.selectionEnd
  readonly property alias selectedText: input.selectedText
  readonly property int fontSize: Style.font.body
  readonly property real lineHeight: input.lineCount > 0 ? input.contentHeight / input.lineCount : fontSize * 1.3
  readonly property var colors: ({
    keyword: String(palette.keyword || Color.accent),
    string: String(palette.string || Qt.tint(Color.foreground, "#9000c060")),
    number: String(palette.number || Qt.tint(Color.foreground, "#90e0a000")),
    comment: String(palette.comment || Color.muted),
    identifier: String(palette.identifier || Qt.tint(Color.foreground, "#7000b0c0"))
  })
  signal runCurrent()
  signal runAll()

  // ---- autocomplete ----
  property var completion: null     // Complete.suggest result while the list is open
  property int pick: 0
  property bool typing: false

  function complete() {
    const r = Cmp.suggest(input.text, input.cursorPosition, catalog, engine)
    if (!r.items.length) { completion = null; return }
    completion = r
    pick = 0
  }
  function closeCompletion() { completion = null }
  function dropIfMoved() { if (completion && input.cursorPosition !== completion.end) completion = null }
  function accept(i) {
    const c = completion
    if (!c || !c.items[i]) return
    completion = null
    input.remove(c.start, input.cursorPosition)
    input.insert(c.start, c.items[i].insert)
  }

  function select(a, b) { input.select(a, b) }
  function focusEditor() { input.forceActiveFocus() }
  function replaceAll(t) {
    // remove + insert keep the undo stack, unlike assigning text
    input.remove(0, input.length)
    input.insert(0, t)
    input.cursorPosition = 0
    flick.contentX = 0
    flick.contentY = 0
    input.forceActiveFocus()
  }

  function ensureVisible(rect) {
    const pad = 8
    if (rect.y < flick.contentY) flick.contentY = Math.max(0, rect.y - pad)
    else if (rect.y + rect.height > flick.contentY + flick.height)
      flick.contentY = rect.y + rect.height - flick.height + pad
    if (rect.x < flick.contentX) flick.contentX = Math.max(0, rect.x - 40)
    else if (rect.x + 2 > flick.contentX + flick.width) flick.contentX = rect.x + 40 - flick.width
  }

  Rectangle { anchors.fill: parent; color: Qt.darker(Color.background, 1.15) }

  // ---- line numbers ----
  Rectangle {
    id: gutter
    width: String(Math.max(input.lineCount, 10)).length * ed.fontSize * 0.62 + 20
    height: parent.height
    color: Qt.darker(Color.background, 1.05)
    clip: true
    Repeater {
      // only the lines in view
      model: Math.min(input.lineCount, Math.ceil(flick.height / ed.lineHeight) + 2)
      delegate: Text {
        required property int index
        readonly property int line: Math.floor(flick.contentY / ed.lineHeight) + index
        visible: line < input.lineCount
        x: 0
        width: gutter.width - 10
        y: input.topPadding + line * ed.lineHeight - flick.contentY
        height: ed.lineHeight
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: line + 1
        color: Color.muted
        font.family: "monospace"
        font.pixelSize: ed.fontSize * 0.85
      }
    }
  }

  Flickable {
    id: flick
    anchors.left: gutter.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    clip: true
    // mouse drags select text; the wheel and scroll bars scroll
    interactive: false
    contentWidth: Math.max(width, input.contentWidth + input.leftPadding + input.rightPadding + 40)
    contentHeight: Math.max(height, input.contentHeight + input.topPadding + input.bottomPadding + height / 2)
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

    WheelHandler {
      onWheel: function(event) {
        const dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * ed.lineHeight * 3
        const dx = event.pixelDelta.x !== 0 ? event.pixelDelta.x : event.angleDelta.x / 120 * ed.lineHeight * 3
        flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY - dy))
        flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - dx))
      }
    }

    TextEdit {
      id: colours
      width: Math.max(flick.width, input.width)
      padding: input.padding
      textFormat: TextEdit.RichText
      readOnly: true
      enabled: false
      activeFocusOnPress: false
      wrapMode: TextEdit.NoWrap
      tabStopDistance: input.tabStopDistance
      font: input.font
      color: Color.foreground
      text: Hl.html(input.text, ed.engine, ed.colors)
    }

    TextEdit {
      id: input
      width: Math.max(flick.width, contentWidth + leftPadding + rightPadding)
      height: Math.max(flick.height, contentHeight + topPadding + bottomPadding)
      padding: 8
      focus: true
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.NoWrap
      selectByMouse: true
      persistentSelection: true
      color: "transparent"
      selectedTextColor: "transparent"
      selectionColor: Qt.alpha(Color.accent, 0.3)
      font.family: "monospace"
      font.pixelSize: ed.fontSize
      tabStopDistance: ed.fontSize * 0.62 * 4
      cursorDelegate: Rectangle {
        width: 2
        color: Color.foreground
        visible: input.activeFocus && blink.on
        Timer { id: blink; property bool on: true; interval: 530; repeat: true; running: input.activeFocus; onTriggered: on = !on }
        Connections { target: input; function onCursorPositionChanged() { blink.on = true; blink.restart() } }
      }
      onCursorRectangleChanged: ed.ensureVisible(cursorRectangle)
      onTextChanged: if (ed.typing) { ed.typing = false; Qt.callLater(ed.complete) }
      // moving the cursor without typing (arrows, a click) closes the list
      onCursorPositionChanged: if (ed.completion && !ed.typing) Qt.callLater(ed.dropIfMoved)
      onActiveFocusChanged: if (!activeFocus) ed.closeCompletion()

      Keys.onPressed: function(event) {
        const ctrl = event.modifiers & Qt.ControlModifier
        const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        const c = ed.completion
        if (c) {
          const n = c.items.length
          if (event.key === Qt.Key_Down) { ed.pick = (ed.pick + 1) % n; event.accepted = true; return }
          if (event.key === Qt.Key_Up) { ed.pick = (ed.pick - 1 + n) % n; event.accepted = true; return }
          if (event.key === Qt.Key_PageDown) { ed.pick = Math.min(n - 1, ed.pick + 8); event.accepted = true; return }
          if (event.key === Qt.Key_PageUp) { ed.pick = Math.max(0, ed.pick - 8); event.accepted = true; return }
          if (event.key === Qt.Key_Escape) { ed.closeCompletion(); event.accepted = true; return }
          if ((enter && !ctrl) || (event.key === Qt.Key_Tab && !ctrl)) { ed.accept(ed.pick); event.accepted = true; return }
        }
        if (ctrl && event.key === Qt.Key_Space) { ed.complete(); event.accepted = true; return }
        if (!ctrl && (/^[A-Za-z0-9_$.]$/.test(event.text) || (c && event.key === Qt.Key_Backspace))) ed.typing = true
        else if (c && event.text !== "") ed.closeCompletion()
        if (ctrl && enter) {
          if (event.modifiers & Qt.ShiftModifier) ed.runAll(); else ed.runCurrent()
          event.accepted = true
        } else if (enter && !(event.modifiers & (Qt.ShiftModifier | Qt.AltModifier))) {
          // keep the indentation of the current line
          const start = text.lastIndexOf("\n", cursorPosition - 1) + 1
          const indent = /^[ \t]*/.exec(text.substring(start, cursorPosition))[0]
          remove(selectionStart, selectionEnd)
          insert(cursorPosition, "\n" + indent)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab && !ctrl) {
          remove(selectionStart, selectionEnd)
          insert(cursorPosition, "  ")
          event.accepted = true
        }
      }
    }
  }

  Rectangle {
    id: completionList
    readonly property real rowHeight: Math.round(ed.fontSize * 1.7)
    readonly property real cx: gutter.width + input.positionToRectangle(ed.completion ? ed.completion.start : 0).x - flick.contentX
    readonly property real below: input.cursorRectangle.y + input.cursorRectangle.height - flick.contentY + 2
    visible: ed.completion !== null && input.activeFocus
    z: 10
    width: Math.min(ed.width - 8, 380)
    height: Math.min(ed.completion ? ed.completion.items.length : 0, 9) * rowHeight + 6
    x: Math.max(4, Math.min(cx - 6, ed.width - width - 4))
    y: below + height <= ed.height ? below : Math.max(0, input.cursorRectangle.y - flick.contentY - height - 2)
    radius: 4
    color: Color.menu.background
    border.color: Color.menu.border
    ListView {
      id: completionView
      anchors.fill: parent
      anchors.margins: 3
      clip: true
      model: ed.completion ? ed.completion.items : []
      currentIndex: ed.pick
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      boundsBehavior: Flickable.StopAtBounds
      delegate: Rectangle {
        required property var modelData
        required property int index
        width: completionView.width
        height: completionList.rowHeight
        radius: 3
        color: index === ed.pick ? Qt.alpha(Color.accent, 0.3) : "transparent"
        Text {
          id: kindIcon
          x: 6
          anchors.verticalCenter: parent.verticalCenter
          width: ed.fontSize * 1.3
          text: ({ column: "\uf0db", table: "\uf0ce", view: "\uf06e", schema: "\uf1c0", keyword: "\uf121" })[modelData.kind] || ""
          color: modelData.kind === "keyword" ? Color.muted : Color.accent
          font.family: Style.font.family
          font.pixelSize: ed.fontSize * 0.85
        }
        Text {
          anchors.left: kindIcon.right
          anchors.leftMargin: 4
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * 0.55
          elide: Text.ElideRight
          text: modelData.label
          color: Color.foreground
          font.family: "monospace"
          font.pixelSize: ed.fontSize * 0.9
        }
        Text {
          anchors.right: parent.right
          anchors.rightMargin: 6
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * 0.35
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideRight
          text: modelData.detail
          color: Color.muted
          font.family: "monospace"
          font.pixelSize: ed.fontSize * 0.75
        }
        MouseArea {
          anchors.fill: parent
          onClicked: { ed.pick = index; ed.accept(index); input.forceActiveFocus() }
        }
      }
    }
  }
}
