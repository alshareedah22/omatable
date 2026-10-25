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
    text: ""
    tooltipText: "OmaTable"
    onPressed: function() { Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "blackcode.omatable", "{}"]) }
  }
}
