# Synology Finder

A native macOS app, written in Swift for Apple silicon, that finds Synology NAS devices on your local network. It replaces Synology Assistant, which is an Intel-only Qt app that will stop working when macOS drops Rosetta.

Like Synology Assistant, it finds devices that have not been set up yet (a NAS fresh out of the box that is not running DSM), because discovery uses Synology's own UDP broadcast protocol rather than anything DSM provides. See [PROTOCOL.md](PROTOCOL.md) for how that protocol works, recovered by reverse engineering and checked against real devices.

This project is not affiliated with Synology. Synology and DiskStation are trademarks of Synology Inc.

## Features

- Lists each server's name, IP address, IP status (manual or DHCP), status, MAC address, DSM version, model and serial number.
- A server with more than one network port is shown as one row, with an ellipsis after the IP and MAC address. Expand it to see each port.
- Connect opens the server's DSM web interface (double-click a row, use the toolbar, or right-click).
- Wake-on-LAN: Set Up WOL remembers a server, including its MAC addresses, so it stays in the list as Offline and can be woken with Wake Up.
- Search across names, addresses, models, serial numbers and versions.
- A scan takes about three to four seconds.
- If macOS has not yet granted Local Network access, the app waits instead of running a scan that would find nothing, then starts scanning as soon as access is available. Synology Assistant scans before the permission prompt is answered, so its first scan is always empty.
- Quits when its window is closed.

## Requirements

- Apple silicon Mac running macOS 14 or later.
- To build: a Swift 6 toolchain (developed with Xcode 27).

## Install

Download `SynologyFinder-1.0-arm64.zip` from the [releases](../../releases) page and move the app to Applications. The app is ad-hoc signed and not notarised, so macOS will refuse to open a downloaded copy the first time. Either right-click it and choose Open, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Synology Finder.app"
```

On first launch, click Allow when macOS asks whether the app may find devices on your local network. If you chose Don't Allow, turn Synology Finder on under System Settings > Privacy & Security > Local Network.

## Build

```bash
cd SynologyFinder
./Scripts/build-app.sh    # builds build/Synology Finder.app (arm64, ad-hoc signed)
swift test                # unit tests
```

The build script compiles in `~/Library/Caches/SynologyFinder-build` because iCloud-synced folders such as `~/Documents` add extended attributes that make code signing fail. Run `swift test` with `--scratch-path` pointing outside such a folder if you hit the same error.

`BUNDLE_ID=com.example.test ./Scripts/build-app.sh` builds a copy under a different bundle identifier, which macOS treats as a new app. Use it to see the first-run Local Network prompt again, because `tccutil reset` does not clear Local Network permission.

## Project layout

- `PROTOCOL.md`: the discovery protocol.
- `SynologyFinder/Sources/SynologyDiscovery`: the library. Packet encoding and decoding, the UDP scanner, Wake-on-LAN, and detection of VPN-routed networks. The scanner can also sweep extra subnets by unicast, which the app does not use (see below).
- `SynologyFinder/Sources/SynologyFinder`: the SwiftUI app.
- `SynologyFinder/Tests`: unit tests, including decoding a reply captured from a real DS918+.
- `SynologyFinder/Resources/AppIcon.png`: the app icon. The build script turns it into an `.icns`.

## Limitations

- **Only the local subnet can be scanned.** A Synology answers discovery only when the probe comes from its own subnet. Routed networks, including site-to-site VPNs, get no reply even though ping and the DSM web interface work. Private networks reached through a VPN are shown greyed out in the toolbar menu, with a tooltip saying why. To find servers on another network, run the app on a computer on that network.
- **Only the "Ready" status is mapped.** Other state codes show as "Unknown (n)". They need an unconfigured or migratable NAS to identify.
- **Wake-on-LAN sends the standard magic packet** to the broadcast address, each local interface and the server's subnet. It has been unit tested but not yet seen waking a powered-off NAS. It needs Wake-on-LAN enabled in DSM and, from another network, a router that forwards directed broadcasts.
- **Other Synology Assistant features** (installing DSM, system recovery, memory test, network setup) are not implemented.

## Licence

[MIT](LICENSE).
