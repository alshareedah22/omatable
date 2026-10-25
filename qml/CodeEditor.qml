import QtQuick
import QtQuick.Controls
import qs.Commons
import "SqlHighlight.js" as Hl

// SQL editor: a plain, transparent TextEdit for typing over a rich-text copy
// that shows the colours. Both use the same font, padding and no wrapping,
// so every glyph of the colour layer sits under the one being edited.
FocusScope {
  id: ed

  property alias text: input.text
  property string engine: ""
  property var palette: ({})
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

      Keys.onPressed: function(event) {
        const ctrl = event.modifiers & Qt.ControlModifier
        const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
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
}
