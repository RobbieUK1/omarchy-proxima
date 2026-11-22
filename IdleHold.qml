import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
  id: root

  // Hyprland needs a mapped surface to honor a Wayland idle inhibitor.
  visible: screen !== null
  screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  anchors { top: true; left: true }
  implicitWidth: 1
  implicitHeight: 1
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  WlrLayershell.namespace: "proxima"
  color: "transparent"
  mask: Region {}

  IdleInhibitor {
    window: root
    enabled: root.visible
  }
}
