import Foundation

/// Wire format of the Synology Assistant discovery protocol. See PROTOCOL.md.
enum Packet {
    static let header = Data([0x12, 0x34, 0x56, 0x78, 0x53, 0x59, 0x4E, 0x4F])  // 12345678 "SYNO"
    static let port: UInt16 = 9999

    enum Field {
        static let packetType: UInt8 = 0x01
        static let name: UInt8 = 0x11
        static let ip: UInt8 = 0x12
        static let netmask: UInt8 = 0x13
        static let gateway: UInt8 = 0x14
        static let dns: UInt8 = 0x15
        static let ipAssignment: UInt8 = 0x18
        static let mac: UInt8 = 0x19
        static let build: UInt8 = 0x49
        static let state: UInt8 = 0x48
        static let httpPort: UInt8 = 0x75
        static let httpsPort: UInt8 = 0x76
        static let version: UInt8 = 0x77
        static let model: UInt8 = 0x78
        static let findHostVersion: UInt8 = 0xA4
        static let serial: UInt8 = 0xC0
    }

    static let typeQuery: UInt32 = 1
    static let typeResponse: UInt32 = 2

    /// Smallest query the NAS answers: protocol version + packet type.
    static func query() -> Data {
        var data = header
        data.append(field: Field.findHostVersion, uint32: 0x0102_0000)
        data.append(field: Field.packetType, uint32: typeQuery)
        return data
    }

    /// Parses a datagram into a field table. Returns nil if the header or any length is invalid.
    static func parse(_ data: Data) -> [UInt8: Data]? {
        let bytes = [UInt8](data)
        guard bytes.count >= header.count, Array(bytes.prefix(header.count)) == [UInt8](header) else { return nil }
        var fields: [UInt8: Data] = [:]
        var i = header.count
        while i < bytes.count {
            guard i + 2 <= bytes.count else { return nil }
            let id = bytes[i]
            let length = Int(bytes[i + 1])
            guard i + 2 + length <= bytes.count else { return nil }
            fields[id] = Data(bytes[(i + 2)..<(i + 2 + length)])
            i += 2 + length
        }
        return fields
    }
}

extension Data {
    fileprivate mutating func append(field id: UInt8, uint32 value: UInt32) {
        append(contentsOf: [id, 4])
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Little-endian unsigned integer of 1...8 bytes.
    var littleEndianInt: UInt64? {
        guard !isEmpty, count <= 8 else { return nil }
        return reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    var stringValue: String? { String(data: self, encoding: .utf8) }

    /// Dotted quad for a 4-byte value kept in network byte order.
    var ipv4String: String? {
        count == 4 ? map(String.init).joined(separator: ".") : nil
    }
}
