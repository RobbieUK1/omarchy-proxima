import argparse
import json
import re
import signal
import sys
import time
from dataclasses import dataclass

BLUEZ = "org.bluez"
ADAPTER = BLUEZ + ".Adapter1"
DEVICE = BLUEZ + ".Device1"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
PROPERTIES = "org.freedesktop.DBus.Properties"
ADDRESS = re.compile(r"(?:[0-9A-F]{2}:){5}[0-9A-F]{2}")
ADDRESS_TYPES = ("public", "random")
DEVICE_METADATA = {"Address", "AddressType", "Adapter", "Alias", "Name", "Paired", "Connected"}
PRESENCE_SECONDS = 15
LIST_SECONDS = 60
LEASE_SECONDS = 3
RETRY_SECONDS = 4
HYSTERESIS_DB = 5
MAX_DEVICES = 80


def boot_time():
    # CLOCK_BOOTTIME advances through suspend, unlike a regular monotonic clock.
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def publish(state, devices=(), rssi=None, until=0):
    print(json.dumps({"state": state, "devices": devices, "rssi": rssi, "until": until}), flush=True)


@dataclass
class Device:
    address: str
    address_type: str
    adapter: str
    name: str
    paired: bool
    connected: bool
    rssi: int | None = None
    seen_until: float = 0
    near_until: float = 0

    @classmethod
    def from_properties(cls, properties):
        address = str(properties.get("Address", "")).upper()
        address_type = str(properties.get("AddressType", ""))
        adapter = str(properties.get("Adapter", ""))
        if not ADDRESS.fullmatch(address) or address_type not in ADDRESS_TYPES or not adapter:
            return None
        name = ""
        for field in ("Alias", "Name"):
            value = str(properties.get(field, ""))[:80]
            label = "".join(char for char in value if char.isprintable()).strip()
            if label and label.upper().replace("-", ":") != address:
                name = label
                break
        return cls(address, address_type, adapter, name, bool(properties.get("Paired")),
                   bool(properties.get("Connected")))

    @property
    def identity(self):
        return self.address, self.address_type

    def signal(self, now):
        return self.rssi if now < self.seen_until else None

    def record(self, now):
        private = self.address_type == "random" and (int(self.address[:2], 16) & 0xC0) != 0xC0
        return {"address": self.address, "addressType": self.address_type, "name": self.name,
                "paired": self.paired, "connected": self.connected, "rssi": self.signal(now),
                "privateAddress": private and not self.paired}


class Discovery:
    def __init__(self, dbus, bus, target, threshold):
        self.dbus = dbus
        self.bus = bus
        self.target = target
        self.threshold = threshold
        self.adapters = {}
        self.devices = {}
        self.scanning = set()
        self.state = "starting"
        self.refresh_at = 0
        self.owner = None
        bus.add_signal_receiver(self.interfaces_added, "InterfacesAdded", OBJECT_MANAGER, BLUEZ, "/")
        bus.add_signal_receiver(self.interfaces_removed, "InterfacesRemoved", OBJECT_MANAGER, BLUEZ, "/")
        bus.add_signal_receiver(self.properties_changed, "PropertiesChanged", PROPERTIES, BLUEZ,
                                path_keyword="path")
        self.owner_watch = bus.watch_name_owner(BLUEZ, self.owner_changed)

    def owner_changed(self, owner):
        if owner == self.owner:
            return
        self.owner = owner
        self.adapters.clear()
        self.devices.clear()
        self.scanning.clear()
        self.state = "starting" if owner else "unavailable"
        self.refresh_at = 0

    def observe(self, device, rssi):
        if device.adapter not in self.scanning or rssi is None or not -127 <= rssi <= 20 or rssi == 0:
            return
        now = boot_time()
        device.rssi = int(rssi)
        device.seen_until = now + PRESENCE_SECONDS
        if device.identity == self.target:
            cutoff = self.threshold - HYSTERESIS_DB if now < device.near_until else self.threshold
            if rssi >= cutoff:
                device.near_until = now + PRESENCE_SECONDS

    def forget_observations(self, adapter):
        self.scanning.discard(adapter)
        for device in self.devices.values():
            if device.adapter == adapter:
                device.seen_until = device.near_until = 0

    def interfaces_added(self, path, interfaces):
        if ADAPTER in interfaces:
            self.refresh_at = 0
        if DEVICE in interfaces:
            properties = interfaces[DEVICE]
            device = Device.from_properties(properties)
            if device is not None:
                self.devices[path] = device
                self.observe(device, properties.get("RSSI"))

    def interfaces_removed(self, path, interfaces):
        if DEVICE in interfaces:
            self.devices.pop(path, None)
        if ADAPTER in interfaces:
            self.adapters.pop(path, None)
            self.forget_observations(path)
            self.refresh_at = 0

    def properties_changed(self, interface, changed, invalidated, path):
        if interface == ADAPTER and ("Powered" in changed or "Discovering" in changed):
            power_lost = "Powered" in changed and not changed["Powered"]
            discovery_lost = "Discovering" in changed and not changed["Discovering"]
            if power_lost or discovery_lost:
                self.forget_observations(path)
                self.refresh_at = 0
            if changed.get("Powered"):
                self.refresh_at = 0
            return
        if interface != DEVICE:
            return
        device = self.devices.get(path)
        if device is None:
            return
        if DEVICE_METADATA.intersection(changed) or DEVICE_METADATA.intersection(invalidated):
            # BlueZ can change a device's reported address when it resolves an existing bond.
            properties = {"Address": device.address, "AddressType": device.address_type,
                          "Adapter": device.adapter, "Alias": device.name, "Paired": device.paired,
                          "Connected": device.connected}
            properties.update(changed)
            for field in invalidated:
                properties.pop(field, None)
            if "Name" in changed and "Alias" not in changed and not device.name:
                properties["Alias"] = changed["Name"]
            updated = Device.from_properties(properties)
            if updated is None:
                self.devices.pop(path, None)
                return
            if updated.identity == device.identity and updated.adapter == device.adapter:
                updated.rssi, updated.seen_until, updated.near_until = (
                    device.rssi, device.seen_until, device.near_until)
            device = self.devices[path] = updated
        if "RSSI" in invalidated:
            device.seen_until = device.near_until = 0
        self.observe(device, changed.get("RSSI"))

    def refresh(self):
        self.refresh_at = boot_time() + RETRY_SECONDS
        if not self.owner:
            self.state = "unavailable"
            return
        manager = self.dbus.Interface(self.bus.get_object(self.owner, "/", introspect=False), OBJECT_MANAGER)
        try:
            objects = manager.GetManagedObjects(timeout=2)
        except self.dbus.DBusException:
            # Closing this D-Bus connection on exit releases our discovery sessions.
            self.scanning.clear()
            self.devices.clear()
            self.state = "unavailable"
            return

        self.adapters = {path: interfaces[ADAPTER] for path, interfaces in objects.items()
                         if ADAPTER in interfaces}
        powered = {path for path, properties in self.adapters.items() if properties.get("Powered")}
        for path in self.scanning - powered:
            self.forget_observations(path)
        devices = {}
        for path, interfaces in objects.items():
            if DEVICE not in interfaces:
                continue
            device = Device.from_properties(interfaces[DEVICE])
            if device is None:
                continue
            previous = self.devices.get(path)
            if previous and previous.identity == device.identity and previous.adapter == device.adapter:
                device.rssi, device.seen_until, device.near_until = (
                    previous.rssi, previous.seen_until, previous.near_until)
            # GetManagedObjects can return a cached RSSI from an earlier scan.
            devices[path] = device
        self.devices = devices

        scan_filter = self.dbus.Dictionary({"Transport": "auto", "DuplicateData": True,
                                            "RSSI": self.dbus.Int16(-127)}, signature="sv")
        for path in sorted(powered - self.scanning):
            adapter = self.dbus.Interface(self.bus.get_object(self.owner, path, introspect=False), ADAPTER)
            try:
                adapter.SetDiscoveryFilter(scan_filter, timeout=2)
                adapter.StartDiscovery(timeout=5)
            except self.dbus.DBusException as error:
                if error.get_dbus_name() != "org.bluez.Error.InProgress":
                    continue
            self.scanning.add(path)

        if self.scanning:
            self.state = "away" if self.target else "scanning"
        elif powered:
            self.state = "unavailable"
        else:
            self.state = "bluetooth-off" if self.adapters else "no-adapter"

        if powered and self.scanning == powered:
            self.refresh_at = float("inf")

    def tick(self):
        if boot_time() >= self.refresh_at:
            self.refresh()
        now = boot_time()
        candidates = [device for device in self.devices.values()
                      if device.paired or (device.seen_until
                          and now < device.seen_until + LIST_SECONDS - PRESENCE_SECONDS)]
        candidates.sort(key=lambda device: (device.identity != self.target, device.signal(now) is None,
                                            -(device.signal(now) or -128), not device.paired, device.address))
        records = {}
        for device in candidates:
            records.setdefault(device.identity, device.record(now))
            if len(records) == MAX_DEVICES:
                break

        selected = [device for device in self.devices.values()
                    if device.identity == self.target and device.adapter in self.scanning]
        rssi = max((device.rssi for device in selected if device.signal(now) is not None), default=None)
        remaining = max((device.near_until - now for device in selected), default=0)
        if remaining > 0:
            until = int((time.time() + min(remaining, LEASE_SECONDS)) * 1000)
            publish("near", list(records.values()), rssi, until)
        else:
            publish(self.state, list(records.values()), rssi)
        return True


def main():
    parser = argparse.ArgumentParser(description="Report current Bluetooth proximity as JSON lines.")
    parser.add_argument("--address", type=str.upper)
    parser.add_argument("--address-type", choices=ADDRESS_TYPES, default="public")
    parser.add_argument("--threshold", type=int, choices=range(-127, 21), default=-70,
                        metavar="DBM")
    args = parser.parse_args()
    if args.address and not ADDRESS.fullmatch(args.address):
        parser.error("expected a Bluetooth MAC address")
    target = (args.address, args.address_type) if args.address else None
    publish("starting")
    try:
        import dbus
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib
    except ImportError as error:
        print(f"Proxima needs python-dbus and python-gobject: {error}", file=sys.stderr)
        publish("dependencies-missing")
        return 1

    try:
        from gi.repository import GLibUnix
        add_unix_signal = GLibUnix.signal_add
    except ImportError:
        add_unix_signal = GLib.unix_signal_add

    DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SystemBus(private=True)
    except dbus.DBusException as error:
        print(f"Proxima could not connect to the system D-Bus: {error}", file=sys.stderr)
        publish("unavailable")
        return 1
    loop = GLib.MainLoop()
    bus.call_on_disconnection(lambda _: loop.quit())
    discovery = Discovery(dbus, bus, target, args.threshold)
    GLib.timeout_add(1000, discovery.tick)
    add_unix_signal(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: loop.quit())
    add_unix_signal(GLib.PRIORITY_DEFAULT, signal.SIGINT, lambda: loop.quit())
    try:
        loop.run()
    finally:
        bus.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
