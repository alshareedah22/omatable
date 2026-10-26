import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Ui

// The tables of a schema as boxes, with a line for each foreign key from its
// column to the column it references. Linked tables are laid out in layers
// (referenced tables first); drag a box by its title to move it, Ctrl+wheel
// zooms, click a title to open the table.
Item {
  id: dg

  property var helper: null
  property string sid: ""
  property var schemas: []
  property string schema: ""
  property bool active: false
  readonly property bool dirty: false
  property var tables: []
  property var links: []
  property var pos: []              // [{x, y}] per table, in diagram units
  property bool loading: false
  property string error: ""
  property bool truncated: false
  property real zoom: 1
  property int hover: -1
  signal openTable(string schema, string table)
  signal notify(string text)

  readonly property int boxW: 220
  readonly property int headH: 26
  readonly property int rowH: 18
  readonly property int maxRows: 14
  readonly property int gapX: 90
  readonly property int gapY: 40

  function boxH(t) { return headH + Math.min(t.columns.length, maxRows) * rowH + (t.columns.length > maxRows ? rowH : 0) + 6 }
  function indexOf(s, name) { return tables.findIndex(function(t) { return t.schema === s && t.name === name }) }

  function load() {
    loading = true
    error = ""
    helper.request("schema.relations", { session: sid, schema: schema || null }, function(r, e) {
      loading = false
      if (e) { error = e.message; return }
      tables = r.tables
      links = r.links.map(function(l) {
        return { name: l.name, a: indexOf(l.from[0], l.from[1]), b: indexOf(l.to[0], l.to[1]), ac: l.from[2][0], bc: l.to[2][0] }
      }).filter(function(l) { return l.a >= 0 && l.b >= 0 })
      truncated = r.truncated
      layout()
    })
  }

  // Components of linked tables, each laid out in columns by distance from its
  // most referenced table; lone tables go in a grid below.
  function layout() {
    const n = tables.length
    const nb = []
    for (let i = 0; i < n; i++) nb.push([])
    const refd = new Array(n).fill(0)
    for (const l of links) { if (l.a !== l.b) { nb[l.a].push(l.b); nb[l.b].push(l.a) } refd[l.b]++ }
    const seen = new Array(n).fill(false)
    const out = new Array(n)
    let y0 = 0
    const lone = []
    const order = [...Array(n).keys()].sort(function(a, b) { return refd[b] - refd[a] || nb[b].length - nb[a].length })
    for (const start of order) {
      if (seen[start]) continue
      if (!nb[start].length) { seen[start] = true; lone.push(start); continue }
      const layers = []
      const queue = [[start, 0]]
      seen[start] = true
      while (queue.length) {
        const [i, d] = queue.shift()
        ;(layers[d] = layers[d] || []).push(i)
        for (const j of nb[i]) if (!seen[j]) { seen[j] = true; queue.push([j, d + 1]) }
      }
      let height = 0
      layers.forEach(function(col, d) {
        let y = y0
        for (const i of col) { out[i] = { x: d * (boxW + gapX), y: y }; y += boxH(tables[i]) + gapY }
        height = Math.max(height, y - y0)
      })
      y0 += height + gapY
    }
    const cols = Math.max(1, Math.ceil(Math.sqrt(lone.length * 1.6)))
    let rowTop = y0, rowMax = 0
    lone.forEach(function(i, k) {
      if (k && k % cols === 0) { rowTop += rowMax + gapY; rowMax = 0 }
      out[i] = { x: (k % cols) * (boxW + gapX / 2), y: rowTop }
      rowMax = Math.max(rowMax, boxH(tables[i]))
    })
    pos = out
    Qt.callLater(fit)
  }

  readonly property var bounds: {
    let w = 0, h = 0
    for (let i = 0; i < pos.length; i++) if (pos[i]) { w = Math.max(w, pos[i].x + boxW); h = Math.max(h, pos[i].y + boxH(tables[i])) }
    return { w: w + 40, h: h + 40 }
  }
  function fit() {
    if (!bounds.w) return
    zoom = Math.max(0.25, Math.min(1.2, Math.min(flick.width / bounds.w, flick.height / bounds.h)))
    flick.contentX = 0
    flick.contentY = 0
  }
  function setZoom(z) { zoom = Math.max(0.2, Math.min(2.5, z)) }

  function rowY(i, col) {
    const t = tables[i]
    const k = t.columns.findIndex(function(c) { return c.name === col })
    return pos[i].y + headH + (k >= 0 && k < maxRows ? k * rowH + rowH / 2 : -headH / 2)
  }

  Component.onCompleted: load()
  onPosChanged: lines.requestPaint()
  onHoverChanged: lines.requestPaint()

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    Rectangle {
      Layout.fillWidth: true
      implicitHeight: bar.implicitHeight + 10
      color: Qt.lighter(Color.background, 1.08)
      RowLayout {
        id: bar
        x: 8
        width: parent.width - 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
        Ui.Dropdown {
          visible: dg.schemas.length > 1
          Layout.preferredWidth: 200
          showLabel: false
          options: dg.schemas
          value: dg.schema
          onChanged: function(v) { dg.schema = v; dg.load() }
        }
        Text {
          Layout.fillWidth: true
          text: dg.loading ? "Loading…" : dg.tables.length + " tables · " + dg.links.length + " links"
            + (dg.truncated ? " · the first " + dg.tables.length + " only" : "")
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Ui.Button { bordered: true; text: "−"; tooltipText: "Zoom out (Ctrl+wheel)"; onClicked: dg.setZoom(dg.zoom / 1.2) }
        Text { text: Math.round(dg.zoom * 100) + "%"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        Ui.Button { bordered: true; text: "+"; tooltipText: "Zoom in (Ctrl+wheel)"; onClicked: dg.setZoom(dg.zoom * 1.2) }
        Ui.Button { bordered: true; text: "Fit"; onClicked: dg.fit() }
        Ui.Button { bordered: true; text: "Arrange"; tooltipText: "Lay the boxes out again"; onClicked: dg.layout() }
        Ui.Button { text: ""; tooltipText: "Reload"; onClicked: dg.load() }
      }
    }
    Text {
      Layout.fillWidth: true
      Layout.margins: 8
      visible: dg.error !== ""
      text: dg.error
      color: Color.urgent
      wrapMode: Text.Wrap
      font.family: "monospace"
      font.pixelSize: Style.font.bodySmall
    }

    Flickable {
      id: flick
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      contentWidth: Math.max(width, dg.bounds.w * dg.zoom)
      contentHeight: Math.max(height, dg.bounds.h * dg.zoom)
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

      WheelHandler {
        acceptedModifiers: Qt.ControlModifier
        onWheel: function(event) { dg.setZoom(dg.zoom * (event.angleDelta.y > 0 ? 1.1 : 1 / 1.1)) }
      }

      Item {
        id: world
        width: dg.bounds.w
        height: dg.bounds.h
        scale: dg.zoom
        transformOrigin: Item.TopLeft
        x: 20 * dg.zoom
        y: 20 * dg.zoom

        Canvas {
          id: lines
          anchors.fill: parent
          onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.lineWidth = 1.6
            for (const l of dg.links) {
              const a = dg.pos[l.a], b = dg.pos[l.b]
              if (!a || !b) continue
              const lit = dg.hover === l.a || dg.hover === l.b
              ctx.strokeStyle = lit ? String(Color.accent) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, dg.hover >= 0 ? 0.15 : 0.45)
              ctx.fillStyle = ctx.strokeStyle
              const y1 = dg.rowY(l.a, l.ac), y2 = dg.rowY(l.b, l.bc)
              let x1, x2, d
              if (l.a === l.b) { x1 = a.x + dg.boxW; x2 = x1; d = 40 }
              else if (b.x >= a.x + dg.boxW / 2) { x1 = a.x + dg.boxW; x2 = b.x; d = Math.max(40, (x2 - x1) / 2) }
              else if (b.x + dg.boxW / 2 <= a.x) { x1 = a.x; x2 = b.x + dg.boxW; d = -Math.max(40, (x1 - x2) / 2) }
              else { x1 = a.x + dg.boxW; x2 = b.x + dg.boxW; d = 50 }
              const back = l.a !== l.b && (x2 === b.x + dg.boxW) && d > 0
              ctx.beginPath()
              ctx.moveTo(x1, y1)
              ctx.bezierCurveTo(x1 + d, y1, back ? x2 + d : x2 - d, y2, x2, y2)
              ctx.stroke()
              // a dot at the referencing column, an arrow at the referenced one
              ctx.beginPath(); ctx.arc(x1, y1, 3, 0, Math.PI * 2); ctx.fill()
              const dir = (back || l.a === l.b) ? -1 : (d > 0 ? 1 : -1)
              ctx.beginPath()
              ctx.moveTo(x2, y2)
              ctx.lineTo(x2 - dir * 8, y2 - 4)
              ctx.lineTo(x2 - dir * 8, y2 + 4)
              ctx.closePath()
              ctx.fill()
            }
          }
        }

        Repeater {
          model: dg.tables.length
          delegate: Rectangle {
            id: box
            required property int index
            readonly property var t: dg.tables[index]
            readonly property var p: dg.pos[index] || { x: 0, y: 0 }
            x: p.x
            y: p.y
            width: dg.boxW
            height: dg.boxH(t)
            radius: 6
            color: Qt.lighter(Color.background, 1.12)
            border.color: dg.hover === index ? Color.accent : Qt.lighter(Color.background, 1.6)
            border.width: dg.hover === index ? 2 : 1
            HoverHandler { onHoveredChanged: dg.hover = hovered ? box.index : (dg.hover === box.index ? -1 : dg.hover) }

            Rectangle {
              id: head
              width: parent.width
              height: dg.headH
              radius: 6
              color: Qt.alpha(Color.accent, 0.25)
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 6; color: parent.color }
              Text {
                x: 10
                width: parent.width - 20
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: (dg.schemas.length > 1 && !dg.schema ? box.t.schema + "." : "") + box.t.name
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              DragHandler {
                id: drag
                target: null
                property point start
                onActiveChanged: if (active) start = Qt.point(box.p.x, box.p.y)
                onTranslationChanged: {
                  if (!active) return
                  const copy = dg.pos.slice()
                  copy[box.index] = { x: Math.max(0, start.x + translation.x), y: Math.max(0, start.y + translation.y) }
                  dg.pos = copy
                }
              }
              TapHandler { onTapped: dg.openTable(box.t.schema, box.t.name) }
            }
            Column {
              x: 8
              y: dg.headH + 3
              width: parent.width - 16
              Repeater {
                model: box.t.columns.slice(0, dg.maxRows)
                delegate: Item {
                  required property var modelData
                  width: parent.width
                  height: dg.rowH
                  Text {
                    id: cname
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * 0.58
                    elide: Text.ElideRight
                    text: (modelData.pk ? " " : "") + modelData.name
                    color: modelData.pk ? Color.accent : Color.foreground
                    font.family: "monospace"
                    font.pixelSize: Style.font.bodySmall * 0.95
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * 0.4
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    text: modelData.type
                    color: Color.muted
                    font.family: "monospace"
                    font.pixelSize: Style.font.bodySmall * 0.85
                  }
                }
              }
              Text {
                visible: box.t.columns.length > dg.maxRows
                height: dg.rowH
                text: "+ " + (box.t.columns.length - dg.maxRows) + " more"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall * 0.9
              }
            }
          }
        }
      }
      Text {
        anchors.centerIn: parent
        visible: !dg.loading && dg.tables.length === 0 && dg.error === ""
        text: "No tables here"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }
}
