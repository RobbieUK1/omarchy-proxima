pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
  id: root

  readonly property bool enabled: configuration.enabled
  readonly property var target: configuration.target
  readonly property var observedTarget: target
    ? devices.find(device => device.address === target.address && device.addressType === target.addressType)
    : undefined
  readonly property int threshold: configuration.threshold
  readonly property bool inhibiting: !saving && !settingsError
    && Qt.platform.pluginName.startsWith("wayland")
    && selectionKey !== "" && scannerKey === selectionKey && leaseUntil > 0
    && Quickshell.screens.length > 0
  readonly property string state: settingsError ? "save-error"
    : !ready || saving ? "starting"
    : scanKey === "" ? "off"
    : scanState === "near" && !inhibiting ? "away" : scanState

  property bool ready: false
  property bool saving: false
  property var devices: []
  property var rssi: null

  property var configuration: ({ enabled: false, target: null, threshold: -70 })
  property bool settingsError: false
  property int widgetCount: 0
  property int setupCount: 0
  property string scannerKey: ""
  property string scanState: "starting"
  property real leaseUntil: 0

  readonly property string selectionKey: enabled && target
    ? [target.address, target.addressType, threshold].join(" ") : ""
  readonly property string scanKey: widgetCount > 0 && ready && !saving
    ? (settingsError ? "" : selectionKey) || (setupCount > 0 ? "setup" : "") : ""
  readonly property string configDirectory: Quickshell.env("XDG_CONFIG_HOME")
    || Quickshell.env("HOME") + "/.config"
  readonly property string scannerPath: decodeURIComponent(
    Qt.resolvedUrl("scanner.py").toString().replace(/^file:\/\//, "").split("?")[0])

  function attach() {
    widgetCount += 1
  }

  function detach() {
    widgetCount = Math.max(0, widgetCount - 1)
    if (widgetCount === 0) setupCount = 0
  }

  function startSetup() {
    setupCount += 1
  }

  function stopSetup() {
    setupCount = Math.max(0, setupCount - 1)
  }

  function validThreshold(value) {
    return Number.isInteger(value) && value >= -90 && value <= -35
  }

  function signalLevel(value) {
    return Number.isInteger(value) && value >= -127 && value <= 20 ? value : null
  }

  function validDevice(device) {
    if (!device || typeof device.address !== "string") return null
    if (device.addressType === "beacon") {
      if (!/^[0-9a-f]{16}$/i.test(device.address)) return null
    } else if ((device.addressType !== "public" && device.addressType !== "random")
        || !/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(device.address)) return null
    const address = device.address.toUpperCase()
    const name = typeof device.name === "string"
      ? device.name.slice(0, 120).replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, "").trim()
      : ""
    return {
      address,
      addressType: device.addressType,
      name: name.toUpperCase().replace(/-/g, ":") === address ? "" : name,
      paired: device.paired === true,
      connected: device.connected === true,
      privateAddress: device.privateAddress === true,
      rssi: signalLevel(device.rssi)
    }
  }

  function loadSettings(text) {
    try {
      if (!text.length || text.length > 4096) throw new Error("Invalid settings size")
      const saved = JSON.parse(text)
      const device = validDevice(saved.target)
      if (!validThreshold(saved.threshold) || typeof saved.enabled !== "boolean"
          || (saved.target !== null && !device) || (saved.enabled && !device)) {
        throw new Error("Invalid Proxima settings")
      }
      configuration = { enabled: saved.enabled, target: device, threshold: saved.threshold }
    } catch (error) {
      settingsError = true
    }
    ready = true
  }

  function saveSettings(device, active, level) {
    if (!ready || saving) return false
    const savedDevice = device ? {
      address: device.address,
      addressType: device.addressType,
      name: device.name,
      privateAddress: device.privateAddress
    } : null
    saving = true
    configuration = { enabled: active, target: savedDevice, threshold: level }
    settingsFile.setText(JSON.stringify(configuration, null, 2) + "\n")
    return true
  }

  function setEnabled(value) {
    return (!value || target !== null) && saveSettings(target, value === true, threshold)
  }

  function selectDevice(rawDevice) {
    const device = validDevice(rawDevice)
    return device !== null && saveSettings(device, enabled, threshold)
  }

  function clearDevice() {
    return saveSettings(null, false, threshold)
  }

  function setThreshold(value) {
    return validThreshold(value) && saveSettings(target, enabled, value)
  }

  function revokeLease() {
    leaseUntil = 0
    leaseTimer.stop()
  }

  function reconcileScanner() {
    if (scanner.running) {
      if (scannerKey !== scanKey) scanner.signal(9)
      return
    }
    if (!scanKey || retry.running) return
    scannerKey = scanKey
    scanState = "starting"
    const command = ["/usr/bin/python", "-u", scannerPath]
    if (scanKey !== "setup") {
      command.push("--address", target.address, "--address-type", target.addressType,
                   "--threshold", String(threshold))
    }
    scanner.command = command
    heartbeat.interval = 20000
    heartbeat.restart()
    scanner.running = true
  }

  function receive(line) {
    if (scannerKey === "" || scannerKey !== scanKey) return
    try {
      if (line.length > 131072) throw new Error("Oversized scanner response")
      const report = JSON.parse(line)
      if (["starting", "scanning", "near", "away", "bluetooth-off", "no-adapter",
           "unavailable", "dependencies-missing"].indexOf(report.state) === -1
          || !Array.isArray(report.devices)) throw new Error("Invalid scanner response")
      const found = []
      for (const entry of report.devices.slice(0, 80)) {
        const device = validDevice(entry)
        if (device) found.push(device)
      }
      devices = found
      rssi = signalLevel(report.rssi)
      scanState = report.state
      heartbeat.interval = report.state === "starting" ? 20000 : 8000
      heartbeat.restart()

      const remaining = report.until - Date.now()
      if (report.state === "near" && scannerKey === selectionKey && rssi !== null
          && typeof report.until === "number" && Number.isFinite(remaining) && remaining > 0) {
        const duration = Math.min(3000, Math.ceil(remaining))
        leaseUntil = Date.now() + duration
        leaseTimer.interval = duration
        leaseTimer.restart()
      } else {
        revokeLease()
      }
    } catch (error) {
      revokeLease()
      scanState = "unavailable"
    }
  }

  onScanKeyChanged: {
    revokeLease()
    rssi = null
    if (!scanKey) devices = []
    retry.stop()
    Qt.callLater(root.reconcileScanner)
  }

  FileView {
    id: settingsFile
    path: root.configDirectory + "/omarchy/proxima.json"
    printErrors: false
    onLoaded: if (!root.ready) root.loadSettings(text())
    onLoadFailed: function(error) {
      if (root.ready) return
      root.settingsError = error !== FileViewError.FileNotFound
      root.ready = true
    }
    onSaved: {
      root.settingsError = false
      root.saving = false
    }
    onSaveFailed: {
      root.settingsError = true
      root.saving = false
    }
  }

  Process {
    id: scanner
    stdout: SplitParser { onRead: line => root.receive(line) }
    onExited: {
      heartbeat.stop()
      root.revokeLease()
      root.devices = []
      root.rssi = null
      if (root.scannerKey === root.scanKey && root.scanKey !== "") {
        if (["no-adapter", "bluetooth-off", "unavailable", "dependencies-missing"]
            .indexOf(root.scanState) === -1) root.scanState = "unavailable"
        retry.restart()
      } else {
        Qt.callLater(root.reconcileScanner)
      }
      root.scannerKey = ""
    }
  }

  Timer {
    id: retry
    interval: 5000
    onTriggered: root.reconcileScanner()
  }

  Timer {
    id: heartbeat
    onTriggered: {
      root.revokeLease()
      root.scanState = "unavailable"
      if (scanner.running) scanner.signal(9)
      else retry.restart()
    }
  }

  Timer {
    id: leaseTimer
    onTriggered: root.revokeLease()
  }

  Loader {
    active: root.inhibiting
    source: Qt.resolvedUrl("IdleHold.qml")
  }
}
