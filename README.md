# Proxima

Proxima is an Omarchy top-bar widget that pauses automatic idle locking when a Bluetooth device is nearby. Install it on the Omarchy computer. A compatible device works with its existing Bluetooth broadcasts. There's no companion app, beacon configuration, or pairing step.

## Install

Run this one line from a terminal in your Omarchy session.

```sh
omarchy pkg add bluez python-dbus python-gobject && omarchy plugin add https://github.com/RobbieUK1/omarchy-proxima.git --enable --yes
```

This installs any missing dependencies and adds Proxima to the right side of the Quickshell bar. Turn on Bluetooth on the Omarchy computer before choosing a device.

For a Git-installed copy, use `omarchy plugin update local.proxima` to update. If you installed the earlier ZIP manually, remove that copy with `omarchy plugin remove local.proxima` before running the one-line installer. Proxima stores your device selection separately.

## Choose a device

1. Open **Proxima** on the bar and choose your device from the Bluetooth list. Search by name or paste all or part of a Bluetooth address.
2. Enable monitoring. Stand where you want Proxima to keep Omarchy awake and look for **Idle lock paused**.
3. If needed, adjust the minimum signal. A stronger threshold such as −60 dBm narrows the range. A weaker threshold such as −80 dBm increases it. Check the result again where you expect proximity to end.

The list shows recent Bluetooth sightings and devices BlueZ already knows from pairing. Only fresh signal observations can pause idle locking, even for a paired device. A non-broadcasting device is invisible to Proxima. An unpaired device with a rotating address may show up as a new entry, and Proxima will stop recognizing the saved address. This can happen with phones and other devices that use Bluetooth privacy features.

## Lock behavior

Once Proxima stops receiving a qualifying signal for about 15 seconds, it releases its idle hold. Omarchy then applies its configured idle timeout. Disabling Proxima, Bluetooth becoming unavailable, or losing the scanner also releases the hold. Manual and suspend locks still work. Returning within range leaves an already locked session locked. Omarchy may complete a lock countdown that its screensaver had already started before Proxima detected the device.

Bluetooth signal strength varies with walls, interference, and device position. The Bluetooth address is the identifier, and an unpaired broadcast can be imitated. Use manual locking when you need the session secured immediately.

Proxima stores the selected address, signal threshold, and monitoring preference in `~/.config/omarchy/proxima.json` by default. Scanning runs locally and does not require internet access.

## Remove from the bar

```sh
omarchy plugin disable local.proxima
```

To remove the plugin files as well, run `omarchy plugin remove local.proxima`. The settings file is separate and can be removed if you want to forget the selected device.
