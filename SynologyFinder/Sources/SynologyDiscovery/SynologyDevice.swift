import Foundation

public struct SynologyDevice: Identifiable, Hashable, Sendable, Codable {
    public enum IPAssignment: String, Sendable, Codable {
        case manual = "Manual"
        case dhcp = "DHCP"
    }

    /// One network port of a server: a unit with several ports answers once per port.
    public struct NetworkInterface: Hashable, Sendable, Codable {
        public let ip: String
        public let mac: String
    }

    /// The serial number identifies the physical unit however many ports answered; the MAC is only a
    /// fallback for a reply without one.
    public var id: String { serial.isEmpty ? mac : serial }
    public let name: String
    public let ip: String
    public let netmask: String
    public let gateway: String
    public let dns: String
    public let ipAssignment: IPAssignment
    /// Raw state code from field 0x48. Only 1 (Ready) has been verified against a real unit.
    public let stateCode: Int
    public let mac: String
    public let dsmVersion: String
    public let model: String
    public let serial: String
    public let httpPort: Int
    public let httpsPort: Int
    /// False for a remembered (Wake-on-LAN) server that did not answer the latest scan.
    public var isOnline = true
    /// The other ports of this server that answered, in the order they were found.
    public private(set) var otherInterfaces: [NetworkInterface] = []

    /// Every port that answered, the one shown in the table first.
    public var interfaces: [NetworkInterface] { [NetworkInterface(ip: ip, mac: mac)] + otherInterfaces }

    /// The table's IP and MAC text: the main one, with an ellipsis when the server has more ports.
    public var ipSummary: String { otherInterfaces.isEmpty ? ip : "\(ip)…" }
    public var macSummary: String { otherInterfaces.isEmpty ? mac : "\(mac)…" }

    /// Folds another port of the same server into this one. Returns false if `other` is a different
    /// server, or a port already known.
    @discardableResult
    public mutating func merge(_ other: SynologyDevice) -> Bool {
        guard other.id == id, !interfaces.contains(where: { $0.mac == other.mac }) else { return false }
        otherInterfaces.append(NetworkInterface(ip: other.ip, mac: other.mac))
        return true
    }

    public var status: String { !isOnline ? "Offline" : stateCode == 1 ? "Ready" : "Unknown (\(stateCode))" }

    /// Broadcast address of this server's subnet, the target for waking it from another network.
    public var subnetBroadcast: String? { IPv4.broadcast(ip: ip, netmask: netmask) }

    public var webURL: URL? { URL(string: "http://\(ip):\(httpPort)") }

    /// Builds a device from a response datagram; nil if it is not a valid response.
    init?(datagram: Data) {
        guard let f = Packet.parse(datagram),
              f[Packet.Field.packetType]?.littleEndianInt == UInt64(Packet.typeResponse),
              let mac = f[Packet.Field.mac]?.stringValue,
              let ip = f[Packet.Field.ip]?.ipv4String
        else { return nil }

        func string(_ id: UInt8) -> String { f[id]?.stringValue ?? "" }
        func int(_ id: UInt8) -> Int { Int(f[id]?.littleEndianInt ?? 0) }
        func addr(_ id: UInt8) -> String { f[id]?.ipv4String ?? "" }

        let version = string(Packet.Field.version)
        let build = int(Packet.Field.build)

        self.name = string(Packet.Field.name)
        self.ip = ip
        self.netmask = addr(Packet.Field.netmask)
        self.gateway = addr(Packet.Field.gateway)
        self.dns = addr(Packet.Field.dns)
        self.ipAssignment = int(Packet.Field.ipAssignment) == 0 ? .dhcp : .manual
        self.stateCode = int(Packet.Field.state)
        self.mac = mac.uppercased()
        self.dsmVersion = build > 0 ? "\(version)-\(build)" : version
        self.model = string(Packet.Field.model)
        self.serial = string(Packet.Field.serial)
        self.httpPort = int(Packet.Field.httpPort)
        self.httpsPort = int(Packet.Field.httpsPort)
    }
}
