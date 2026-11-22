pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons as Commons
import qs.Ui as Ui

Ui.KeyboardPanel {
  id: panel

  required property var proxima
  required property var strings
  property bool choosingDevice: false
  property bool scannerRequested: false
  readonly property bool wantsSetupScan: open && choosingDevice && proxima.ready

  readonly property color ink: Commons.Color.popups.text
  readonly property color mutedInk: Qt.tint(ink, Qt.alpha(Commons.Color.popups.background, 0.3))
  readonly property int minimumThreshold: -90
  readonly property int maximumThreshold: -35

  contentWidth: fittedContentWidth(Commons.Style.space(370))
  contentHeight: fittedContentHeight(loadedContentHeight, Commons.Style.space(510))
  focusTarget: loadedContent

  onWantsSetupScanChanged: {
    if (wantsSetupScan && !scannerRequested) {
      proxima.startSetup()
      scannerRequested = true
    } else if (!wantsSetupScan && scannerRequested) {
      proxima.stopSetup()
      scannerRequested = false
    }
  }
  Component.onDestruction: if (scannerRequested && proxima) proxima.stopSetup()

  function statusText() {
    if (proxima.inhibiting) return strings.t("status.near")
    const forcedStatus = ["save-error", "bluetooth-off", "no-adapter", "unavailable", "dependencies-missing"]
    if (forcedStatus.includes(proxima.state)) return strings.t("status." + proxima.state)
    if (!proxima.ready || proxima.state === "starting") return strings.t("status.starting")
    if (!proxima.target) return strings.t("status.pick")
    if (!proxima.enabled) return strings.t("status.off")
    return strings.t("status.away")
  }

  function deviceName(device) {
    return device && device.name ? device.name : strings.t("device.unnamed")
  }

  function signalText(level) {
    return typeof level === "number" && Number.isFinite(level)
      ? strings.t("signal.dbm").arg(Commons.I18n.formatNumber(level))
      : strings.t("signal.unknown")
  }

  function deviceDetails(device) {
    return strings.t(device.paired ? "device.detailsPaired" : "device.detailsUnpaired")
      .arg(device.address).arg(signalText(device.rssi))
  }

  component BodyText: Text {
    textFormat: Text.PlainText
    color: panel.ink
    font.family: Commons.Style.font.family
    font.pixelSize: Commons.Style.font.body
    wrapMode: Text.Wrap
  }

  component PanelButton: Ui.Button {
    foreground: panel.ink
    focusable: true
    bordered: true
  }

  content: FocusScope {
    implicitHeight: column.implicitHeight
    Keys.onEscapePressed: panel.close()

    Flickable {
      id: scroller
      anchors.fill: parent
      clip: true
      contentWidth: width
      contentHeight: column.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

      ColumnLayout {
        id: column
        width: scroller.width
        spacing: Commons.Style.spacing.lg

        BodyText {
          text: panel.strings.t("name")
          font.pixelSize: Commons.Style.font.title
          font.bold: true
        }

        BodyText {
          Layout.fillWidth: true
          text: panel.statusText()
          color: panel.proxima.inhibiting ? Commons.Color.accent : panel.ink
          font.bold: panel.proxima.inhibiting
        }

        Ui.Toggle {
          Layout.fillWidth: true
          visible: !!panel.proxima.target
          enabled: panel.proxima.ready && !panel.proxima.saving && !!panel.proxima.target
          checked: panel.proxima.enabled
          label: panel.strings.t("monitor.label")
          description: panel.strings.t("monitor.description")
          foreground: panel.ink
          onClicked: panel.proxima.setEnabled(!panel.proxima.enabled)
        }

        BodyText {
          Layout.fillWidth: true
          visible: !!panel.proxima.target
          text: panel.deviceName(panel.proxima.target)
          font.pixelSize: Commons.Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
          wrapMode: Text.NoWrap
        }

        BodyText {
          Layout.fillWidth: true
          visible: !!panel.proxima.target
          color: panel.mutedInk
          text: panel.proxima.target ? panel.deviceDetails({
            address: panel.proxima.target.address,
            paired: panel.proxima.target.paired,
            rssi: panel.proxima.rssi
          }) : ""
        }

        BodyText {
          Layout.fillWidth: true
          visible: !!panel.proxima.target && panel.proxima.target.privateAddress === true
          color: panel.mutedInk
          text: panel.strings.t("device.private")
        }

        RowLayout {
          Layout.fillWidth: true
          visible: !!panel.proxima.target || !panel.choosingDevice

          PanelButton {
            text: panel.choosingDevice ? panel.strings.t("device.done") : panel.strings.t("device.choose")
            enabled: panel.proxima.ready
            onClicked: panel.choosingDevice = !panel.choosingDevice
          }

          PanelButton {
            text: panel.strings.t("device.forget")
            visible: !!panel.proxima.target
            enabled: panel.proxima.ready && !panel.proxima.saving
            onClicked: {
              if (panel.proxima.clearDevice()) panel.choosingDevice = true
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          visible: panel.choosingDevice
          spacing: Commons.Style.spacing.sm

          BodyText {
            Layout.fillWidth: true
            text: panel.strings.t("device.scanTitle")
            font.pixelSize: Commons.Style.font.subtitle
            font.bold: true
          }

          BodyText {
            Layout.fillWidth: true
            text: panel.strings.t("device.scanHelp")
            color: panel.mutedInk
          }

          BodyText {
            Layout.fillWidth: true
            visible: deviceRows.count === 0
            text: panel.strings.t("device.waiting")
            color: panel.mutedInk
          }

          Repeater {
            model: deviceRows

            delegate: Item {
              id: row
              required property string deviceKey
              required property var device

              Layout.fillWidth: true
              implicitHeight: rowText.implicitHeight + Commons.Style.spacing.controlPaddingY * 2

              PanelButton {
                id: chooseButton
                anchors.fill: parent
                Accessible.name: panel.deviceName(row.device) + ", " + row.device.address
                enabled: panel.proxima.ready && !panel.proxima.saving
                onActiveFocusChanged: {
                  if (!activeFocus) return
                  const top = row.mapToItem(scroller.contentItem, 0, 0).y
                  const bottom = top + row.height
                  if (top < scroller.contentY) scroller.contentY = top
                  else if (bottom > scroller.contentY + scroller.height)
                    scroller.contentY = bottom - scroller.height
                }
                onClicked: {
                  if (panel.proxima.selectDevice(row.device)) {
                    panel.choosingDevice = false
                    panel.loadedContent.forceActiveFocus()
                  }
                }
              }

              Column {
                id: rowText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Commons.Style.spacing.rowPaddingX
                spacing: Commons.Style.spacing.xxs

                BodyText {
                  width: parent.width
                  text: panel.deviceName(row.device)
                  elide: Text.ElideRight
                  wrapMode: Text.NoWrap
                }

                BodyText {
                  width: parent.width
                  text: panel.deviceDetails(row.device)
                  color: panel.mutedInk
                  font.pixelSize: Commons.Style.font.caption
                  elide: Text.ElideRight
                  wrapMode: Text.NoWrap
                }
              }
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          visible: !!panel.proxima.target && !panel.choosingDevice
          spacing: Commons.Style.spacing.sm

          RowLayout {
            Layout.fillWidth: true

            BodyText {
              Layout.fillWidth: true
              text: panel.strings.t("signal.required")
            }

            PanelButton {
              text: "−"
              Accessible.name: panel.strings.t("signal.weaker")
              enabled: panel.proxima.ready && !panel.proxima.saving
                && panel.proxima.threshold > panel.minimumThreshold
              onClicked: panel.proxima.setThreshold(Math.max(panel.minimumThreshold, panel.proxima.threshold - 5))
            }

            BodyText {
              text: panel.signalText(panel.proxima.threshold)
              font.bold: true
            }

            PanelButton {
              text: "+"
              Accessible.name: panel.strings.t("signal.stronger")
              enabled: panel.proxima.ready && !panel.proxima.saving
                && panel.proxima.threshold < panel.maximumThreshold
              onClicked: panel.proxima.setThreshold(Math.min(panel.maximumThreshold, panel.proxima.threshold + 5))
            }
          }

          BodyText {
            Layout.fillWidth: true
            text: panel.strings.t("signal.help")
            color: panel.mutedInk
          }
        }
      }
    }

    // Update by identity so live signal readings leave focused rows and the
    // scroll position in place.
    ListModel {
      id: deviceRows

      function sync() {
        const next = new Map()
        const devices = panel.choosingDevice ? panel.proxima.devices || [] : []
        for (const device of devices) {
          next.set(device.address + "/" + device.addressType, device)
        }
        for (let index = 0; index < count;) {
          const key = get(index).deviceKey
          if (!next.has(key)) {
            remove(index)
          } else {
            setProperty(index, "device", next.get(key))
            next.delete(key)
            index++
          }
        }
        for (const [key, device] of next) append({ deviceKey: key, device: device })
      }
    }

    Connections {
      target: panel.proxima
      function onDevicesChanged() { deviceRows.sync() }
    }

    Connections {
      target: panel
      function onChoosingDeviceChanged() {
        deviceRows.sync()
        scroller.contentY = 0
      }
    }

    Component.onCompleted: deviceRows.sync()
  }
}
