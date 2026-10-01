import Foundation
import Observation
import SynologyDiscovery


@MainActor @Observable
final class FinderModel {
    enum Phase { case idle, waitingForPermission, scanning }

    private static let wolHostsKey = "wolHosts"

    private(set) var devices: [SynologyDevice] = []
    private(set) var phase = Phase.idle
    private(set) var progress = 0.0
    private(set) var message: String?
    /// Short result of the last action (for example a wake-up), shown in the footer.
    private(set) var notice: String?
    /// Private subnets routed through a VPN or tunnel. They are listed but cannot be scanned: a
    /// Synology only answers discovery from its own subnet (see PROTOCOL.md).
    private(set) var remoteNetworks: [RemoteNetwork] = []
    /// Servers set up for Wake-on-LAN, remembered across launches so they can be woken while offline.
    private(set) var wolHosts: [String: SynologyDevice] = FinderModel.loadWOLHosts()

    private var scanTask: Task<Void, Never>?

    /// Re-reads the routing table, since a VPN may have connected since launch.
    func refreshNetworks() {
        Task { remoteNetworks = await Task.detached { NetworkDetection.detectRemoteNetworks() }.value }
    }

    func isWOLEnabled(_ device: SynologyDevice) -> Bool { wolHosts[device.id] != nil }

    /// Waits until macOS lets this app use the local network (the system prompt answered, or access
    /// turned on in System Settings), then scans. Scanning earlier would find nothing.
    func startScan() {
        scanTask?.cancel()
        devices = []
        message = nil
        notice = nil
        progress = 0
        scanTask = Task {
            phase = .waitingForPermission
            while !Task.isCancelled {
                if await Task.detached(operation: { LocalNetworkAccess.isAvailable() }).value { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            await scan()
        }
    }

    private func scan() async {
        phase = .scanning
        let scanner = DiscoveryScanner()
        let start = Date()
        let ticker = Task {
            while !Task.isCancelled {
                progress = min(1, Date().timeIntervalSince(start) / scanner.duration)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { ticker.cancel() }

        do {
            for try await event in scanner.scan() {
                if case .device(let device) = event {
                    // A server with several ports answers once per port: show it as one row.
                    if let row = devices.firstIndex(where: { $0.id == device.id }) {
                        devices[row].merge(device)
                    } else {
                        devices.append(device)
                    }
                }
            }
        } catch {
            message = "\(error)"
        }
        guard !Task.isCancelled else { return }
        progress = 1
        phase = .idle
        mergeWOLHosts()
        refreshNetworks()
        if devices.isEmpty, message == nil { message = "No Synology servers found on this network." }
    }

    /// Refreshes remembered servers that answered, and lists the ones that did not as offline.
    private func mergeWOLHosts() {
        for device in devices where wolHosts[device.id] != nil { wolHosts[device.id] = device }
        let found = Set(devices.map(\.id))
        for (id, var host) in wolHosts.sorted(by: { $0.value.name < $1.value.name })
        where !found.contains(id) && isDiscoverable(host) {
            host.isOnline = false
            devices.append(host)
        }
        saveWOLHosts()
    }

    /// A remembered server on a VPN network cannot be discovered, so it is not listed as offline.
    private func isDiscoverable(_ host: SynologyDevice) -> Bool {
        let address = IPv4.parse(host.ip) ?? 0
        return !remoteNetworks.contains { $0.subnet.contains(address) }
    }

    func toggleWOL(_ device: SynologyDevice) {
        if wolHosts.removeValue(forKey: device.id) == nil {
            var saved = device
            saved.isOnline = true
            wolHosts[device.id] = saved
        }
        saveWOLHosts()
    }

    func wake(_ device: SynologyDevice) {
        do {
            for port in device.interfaces { try WakeOnLAN.wake(mac: port.mac, subnetBroadcast: device.subnetBroadcast) }
            notice = "Wake-up packet sent to \(device.name). Search again in a minute."
        } catch {
            notice = "\(error)"
        }
    }

    // MARK: Persistence

    private func saveWOLHosts() {
        let online = wolHosts.mapValues { host -> SynologyDevice in var h = host; h.isOnline = true; return h }
        UserDefaults.standard.set(try? JSONEncoder().encode(online), forKey: Self.wolHostsKey)
    }

    private static func loadWOLHosts() -> [String: SynologyDevice] {
        guard let data = UserDefaults.standard.data(forKey: wolHostsKey),
              let hosts = try? JSONDecoder().decode([String: SynologyDevice].self, from: data) else { return [:] }
        return hosts
    }
}
