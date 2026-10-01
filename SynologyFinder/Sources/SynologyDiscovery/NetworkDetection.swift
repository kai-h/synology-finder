import Foundation

/// A private IPv4 network that is reached through a VPN or tunnel rather than the local LAN, so a
/// broadcast cannot reach it but a unicast sweep can.
public struct RemoteNetwork: Identifiable, Hashable, Sendable {
    public var id: String { description }
    public let subnet: IPv4Subnet
    public let interface: String

    public init(subnet: IPv4Subnet, interface: String) {
        self.subnet = subnet
        self.interface = interface
    }

    public var description: String { "\(IPv4.format(subnet.network))/\(subnet.prefix)" }
}

public enum NetworkDetection {
    /// Interface name prefixes macOS uses for tunnels (WireGuard and Tailscale use utun).
    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    /// Private networks routed through a tunnel interface, largest sweep /16 and smallest /30.
    public static func detectRemoteNetworks() -> [RemoteNetwork] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", "inet"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return remoteNetworks(fromRoutingTable: String(decoding: output, as: UTF8.self))
    }

    /// Parses `netstat -rn -f inet` output. Columns are Destination, Gateway, Flags, Netif, [Expire].
    static func remoteNetworks(fromRoutingTable text: String) -> [RemoteNetwork] {
        var found: [RemoteNetwork] = []
        for line in text.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 4 else { continue }
            let interface = String(columns[3])
            guard tunnelPrefixes.contains(where: interface.hasPrefix),
                  let subnet = subnet(fromRouteDestination: String(columns[0])),
                  isPrivate(subnet)
            else { continue }
            let network = RemoteNetwork(subnet: subnet, interface: interface)
            if !found.contains(where: { $0.subnet == subnet }) { found.append(network) }
        }
        return found.sorted { $0.subnet.network < $1.subnet.network }
    }

    /// netstat abbreviates destinations: `10.1/16` means `10.1.0.0/16`. Hosts (no prefix) are skipped.
    static func subnet(fromRouteDestination destination: String) -> IPv4Subnet? {
        let parts = destination.split(separator: "/")
        guard parts.count == 2 else { return nil }
        var octets = parts[0].split(separator: ".").map(String.init)
        guard (1...4).contains(octets.count) else { return nil }
        octets += Array(repeating: "0", count: 4 - octets.count)
        return IPv4Subnet(cidr: "\(octets.joined(separator: "."))/\(parts[1])")
    }

    /// RFC 1918 plus the carrier-grade NAT range that Tailscale-style overlays use.
    static func isPrivate(_ subnet: IPv4Subnet) -> Bool {
        let n = subnet.network
        return n >> 24 == 10
            || n >> 20 == 0xAC1  // 172.16.0.0/12
            || n >> 16 == 0xC0A8  // 192.168.0.0/16
            || n >> 22 == 0x191  // 100.64.0.0/10
    }
}
