import Darwin
import Foundation

public enum LocalNetworkAccess {
    /// Whether this process may send to the local network right now.
    ///
    /// Until the user allows Local Network access, macOS fails sends to local addresses with
    /// EHOSTUNREACH (and shows its prompt on the first attempt). There is no API to ask for the state
    /// directly, and a Bonjour self-discovery probe wrongly reports success while the prompt is still
    /// open, so this makes a real send: an empty datagram to the broadcast discard port, which no
    /// device acts on (and which does not count as a discovery query).
    public static func isAvailable() -> Bool {
        guard let fd = try? Net.udpSocket(port: nil) else { return false }
        defer { close(fd) }
        return Net.send(Data(), fd: fd, to: INADDR_BROADCAST, port: 9) == 0
    }
}
