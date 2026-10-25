import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Bar icon: click opens or closes the OmaTable window (the panel half of this plugin).
BarWidget {
  id: root
  moduleName: "blackcode.omatable"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The glyph only reserves the slot; the color icon below is what shows.
    text: ""
    labelVisible: false
    fixedWidth: vertical ? -1 : icon.width + Style.spaceReal(horizontalMargin) * 2
    tooltipText: "OmaTable"
    onPressed: function() { Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "blackcode.omatable", "{}"]) }

    Image {
      id: icon
      anchors.centerIn: parent
      source: Qt.resolvedUrl("icon.svg")
      width: Math.round(Style.font.body * 1.35)
      height: width
      sourceSize: Qt.size(width * 2, height * 2)
      smooth: true
    }
  }
}
