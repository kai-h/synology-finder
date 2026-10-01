import Foundation
import Testing
@testable import SynologyDiscovery

/// Plain reply captured from a DS918+ running DSM 7.4.1-90080 (see PROTOCOL.md).
private let ds918Reply = "1234567853594e4f191130303a31313a33323a61613a62623a303112040a141f091004000000001304ffffff0018040100000015040101010214040a141f01a30400000000010402000000110a4175746f6d61746963611e040a141fc0c00d5445535453455249414c313233730a54455354534e30313233a40400000201a6047800000050005200540400000000560058005a005c0051005300550400000000570059005b005d00a704010000004804010000004904e05f01007705372e342e31900400000000780644533931382b701873796e6f6c6f67795f61706f6c6c6f6c616b655f3931382bc10344534d8004000000007b04000000007104010000007504d00700007604d10700007c1130323a30303a30303a30303a30303a3030b008bf03000000000000b1080000000000000000b8088100000000000000b9080000000000000000"

private func data(hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map {
        UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
    })
}

@Test func queryMatchesMinimalWireFormat() {
    #expect(Packet.query() == data(hex: "1234567853594e4fa404" + "00000201" + "010401000000"))
}

@Test func decodesCapturedReply() throws {
    let device = try #require(SynologyDevice(datagram: data(hex: ds918Reply)))
    #expect(device.name == "Automatica")
    #expect(device.ip == "10.20.31.9")
    #expect(device.ipAssignment == .manual)
    #expect(device.status == "Ready")
    #expect(device.mac == "00:11:32:AA:BB:01")
    #expect(device.dsmVersion == "7.4.1-90080")
    #expect(device.model == "DS918+")
    #expect(device.serial == "TESTSERIAL123")
    #expect(device.webURL?.absoluteString == "http://10.20.31.9:2000")
}

@Test func rejectsOwnQueryAndGarbage() {
    #expect(SynologyDevice(datagram: Packet.query()) == nil)
    #expect(SynologyDevice(datagram: Data([1, 2, 3])) == nil)
    #expect(Packet.parse(data(hex: "1234567853594e4f1109")) == nil)  // length overruns buffer
}

@Test func magicPacketIs102Bytes() throws {
    let packet = try #require(WakeOnLAN.magicPacket(mac: "00:11:32:AA:BB:01"))
    #expect(packet.count == 102)
    #expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
    #expect(packet.suffix(6) == Data([0x00, 0x11, 0x32, 0xAA, 0xBB, 0x01]))
    #expect(WakeOnLAN.magicPacket(mac: "not a mac") == nil)
}

@Test func subnetParsingAndBroadcast() throws {
    let subnet = try #require(IPv4Subnet(cidr: "192.168.50.77/24"))
    #expect(IPv4.format(subnet.network) == "192.168.50.0")
    #expect(subnet.hosts.count == 254)
    #expect(IPv4.format(subnet.hosts.first!) == "192.168.50.1" && IPv4.format(subnet.hosts.last!) == "192.168.50.254")
    #expect(IPv4Subnet(cidr: "10.0.0.0/8") == nil)  // too large to sweep
    #expect(IPv4Subnet(cidr: "300.1.1.1/24") == nil)
    #expect(IPv4.broadcast(ip: "10.20.31.9", netmask: "255.255.255.0") == "10.20.31.255")
}

@Test func detectsPrivateSubnetsRoutedThroughTunnels() {
    let table = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            10.20.31.1         UGScg                 en1
    10.1/16            link#22            UCS                 utun4
    10.1.0.1           link#22            UHW3I               utun4
    10.20.31/24        link#14            UCS                   en1
    172.16/12          10.6.0.1           UGSc                utun4
    192.168.50/24      10.6.0.1           UGSc                utun4
    8.8.8.8            10.6.0.1           UGHS                utun4
    100.64/10          link#23            UCS                 utun5
    169.254            link#14            UCS                   en1
    """
    let found = NetworkDetection.remoteNetworks(fromRoutingTable: table).map(\.description)
    // 172.16/12 and 100.64/10 are too large to sweep, hosts and LAN routes are not tunnels.
    #expect(found == ["10.1.0.0/16", "192.168.50.0/24"])
}

@Test func mergesPortsOfOneServerByWhichSerial() throws {
    var first = try #require(SynologyDevice(datagram: data(hex: ds918Reply)))
    // Same unit answering from a second port: different MAC (…e1 to …e2) and IP (.9 to .10), same serial.
    let secondHex = ds918Reply
        .replacingOccurrences(of: "3a303112", with: "3a303212")  // last MAC character 1 to 2
        .replacingOccurrences(of: "12040a141f09", with: "12040a141f0a")
    let second = try #require(SynologyDevice(datagram: data(hex: secondHex)))
    #expect(second.ip == "10.20.31.10" && second.mac == "00:11:32:AA:BB:02")
    #expect(first.id == second.id)

    let merged = first.merge(second)
    let mergedAgain = first.merge(second)  // the same port twice changes nothing
    #expect(merged)
    #expect(!mergedAgain)
    #expect(first.ipSummary == "10.20.31.9…")
    #expect(first.interfaces.map(\.ip) == ["10.20.31.9", "10.20.31.10"])
}
