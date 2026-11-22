import QtQuick
import qs.Commons as Commons
import qs.Ui as Ui
import "." as Local

Ui.BarWidget {
  id: root

  moduleName: "local.proxima"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var proxima: Local.ProximaState
  property bool opened: false
  property bool popoutSwitchClosing: false

  Component.onCompleted: proxima.attach()
  Component.onDestruction: proxima.detach()

  function open() {
    if (!bar || opened) return
    panel.choosingDevice = proxima.ready && !proxima.target
    opened = true
  }

  function close() {
    opened = false
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  Commons.Translations {
    id: translations
    directory: Qt.resolvedUrl("i18n")
  }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Commons.Style.bar.statusSlot
    text: root.proxima.inhibiting ? "󰌿" : "󰌾"
    active: root.proxima.inhibiting || root.opened
    activeColor: Commons.Color.accent
    dimmed: root.proxima.ready && !root.proxima.enabled && !root.opened
    tooltipText: root.proxima.inhibiting ? translations.t("bar.near") : translations.t("name")
    Accessible.name: tooltipText
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) {
        if (root.opened) root.close()
        else root.open()
      }
    }
  }

  Local.Panel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    proxima: root.proxima
    strings: translations
  }
}
