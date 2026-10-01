import Darwin
import Foundation

public enum WakeOnLAN {
    public static let port: UInt16 = 9

    /// 6 bytes of 0xFF followed by the MAC address 16 times. Nil if `mac` is not six hex pairs.
    public static func magicPacket(mac: String) -> Data? {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        return Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes })
    }

    /// Sends the magic packet to the limited broadcast address, every local interface's directed
    /// broadcast, and the device's own subnet broadcast (`subnetBroadcast`), which is the one that can
    /// reach a remote site if the router forwards directed broadcasts.
    public static func wake(mac: String, subnetBroadcast: String? = nil) throws {
        guard let packet = magicPacket(mac: mac) else { throw ScanError(description: "Invalid MAC address \(mac)") }
        let fd = try Net.udpSocket(port: nil)
        defer { close(fd) }

        var targets: [in_addr_t] = [INADDR_BROADCAST] + Net.interfaceBroadcasts().map(\.address)
        if let subnetBroadcast, let address = IPv4.parse(subnetBroadcast) { targets.append(in_addr_t(address.bigEndian)) }

        var failure: Int32 = 0
        var delivered = false
        for target in targets {
            let error = Net.send(packet, fd: fd, to: target, port: port)
            if error == 0 { delivered = true } else { failure = error }
        }
        if !delivered { throw ScanError(description: "Could not send: \(String(cString: strerror(failure)))") }
    }
}
