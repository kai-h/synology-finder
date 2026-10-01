import Darwin
import Foundation

/// An IPv4 CIDR block such as `192.168.50.0/24`, used for unicast sweeps of networks that broadcasts
/// cannot reach (for example a site reached over a WireGuard tunnel).
public struct IPv4Subnet: Hashable, Sendable {
    public let network: UInt32  // host byte order
    public let prefix: Int

    /// Accepts `a.b.c.d/n` with n in 16...30 (a bare address means /32).
    public init?(cidr: String) {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let address = IPv4.parse(String(parts[0])) else { return nil }
        let prefix = parts.count == 2 ? Int(parts[1]) : 32
        guard let prefix, prefix == 32 || (16...30).contains(prefix) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : ~0 << UInt32(32 - prefix)
        self.network = address & mask
        self.prefix = prefix
    }

    public func contains(_ address: UInt32) -> Bool {
        prefix == 0 || address >> UInt32(32 - prefix) == network >> UInt32(32 - prefix)
    }

    /// Usable host addresses (network and broadcast addresses excluded).
    public var hosts: [UInt32] {
        guard prefix < 32 else { return [network] }
        let size = UInt32(1) << UInt32(32 - prefix)
        return (1..<(size - 1)).map { network + $0 }
    }
}

public enum IPv4 {
    /// Dotted quad to host-byte-order integer.
    public static func parse(_ string: String) -> UInt32? {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard octets.count == 4, !octets.contains(nil) else { return nil }
        return octets.reduce(0) { $0 << 8 | UInt32($1!) }
    }

    public static func format(_ address: UInt32) -> String {
        (0..<4).map { String(address >> UInt32(24 - 8 * $0) & 0xFF) }.joined(separator: ".")
    }

    /// Directed broadcast address of the subnet containing `ip`.
    public static func broadcast(ip: String, netmask: String) -> String? {
        guard let ip = parse(ip), let mask = parse(netmask) else { return nil }
        return format(ip | ~mask)
    }
}

/// Thin BSD-socket helpers shared by discovery and Wake-on-LAN.
enum Net {
    static func udpSocket(port: UInt16?) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ScanError(description: "socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        for option in [SO_BROADCAST, SO_REUSEADDR, SO_REUSEPORT] {
            setsockopt(fd, SOL_SOCKET, option, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        if let port {
            var local = address(INADDR_ANY, port: port)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else {
                let reason = String(cString: strerror(errno))
                close(fd)
                throw ScanError(description: "Could not listen on UDP port \(port): \(reason)")
            }
        }
        return fd
    }

    static func address(_ host: in_addr_t, port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = host
        return a
    }

    /// Sends one datagram, riding out a full send buffer (a /16 sweep is 65k packets).
    /// Returns 0 on success or the errno.
    @discardableResult
    static func send(_ data: Data, fd: Int32, to host: in_addr_t, port: UInt16) -> Int32 {
        var to = address(host, port: port)
        for _ in 0..<50 {
            let sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent >= 0 { return 0 }
            guard errno == ENOBUFS else { return errno }
            usleep(2000)
        }
        return ENOBUFS
    }

    /// Directed broadcast address of every up, non-loopback, broadcast-capable IPv4 interface.
    static func interfaceBroadcasts() -> [(name: String, address: in_addr_t)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [(String, in_addr_t)] = []
        for p in sequence(first: list, next: { $0?.pointee.ifa_next }).compactMap({ $0 }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let dst = p.pointee.ifa_dstaddr, dst.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let address = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            result.append((String(cString: p.pointee.ifa_name), address))
        }
        return result
    }
}
