import Darwin
import Foundation

public enum ScanEvent: Sendable {
    case device(SynologyDevice)
    /// A query could not be sent to an interface, typically because Local Network access is denied.
    case sendFailed(interface: String, errno: Int32)
}

public struct ScanError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Broadcasts the discovery query (plus a unicast sweep of any extra subnets) and yields devices as
/// they answer.
///
/// A NAS answers only the first query it hears in a burst (about 2 s later) and ignores the rest, so
/// the query is sent once and retried only if nothing has answered. The scan ends shortly after the
/// last reply instead of always running to the time limit.
public struct DiscoveryScanner: Sendable {
    /// Hard time limit.
    public var duration: TimeInterval
    /// Never finish before this, because replies take about 2 s to arrive.
    public var minimumDuration: TimeInterval
    /// Finish this long after the last reply once `minimumDuration` has passed.
    public var settleTime: TimeInterval
    /// Resend the query if nothing has answered by now.
    public var retryAfter: TimeInterval
    /// Networks to sweep by unicast, for subnets that broadcasts do not reach.
    public var extraSubnets: [IPv4Subnet]
    /// Whether to broadcast on the local interfaces. Off for a manual scan of one remote network.
    public var includeBroadcast: Bool

    public init(duration: TimeInterval = 6.5, minimumDuration: TimeInterval = 3, settleTime: TimeInterval = 1,
                retryAfter: TimeInterval = 3.5, extraSubnets: [IPv4Subnet] = [], includeBroadcast: Bool = true) {
        self.duration = duration
        self.minimumDuration = minimumDuration
        self.settleTime = settleTime
        self.retryAfter = retryAfter
        self.extraSubnets = extraSubnets
        self.includeBroadcast = includeBroadcast
    }

    public func scan() -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try run { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tracks the sender thread so the receive loop keeps reading while a large sweep is going out and
    /// only starts its timeouts once the last packet has left.
    private final class SendState: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var finishedAt: Date?

        func begin() { lock.withLock { active += 1 } }
        func end() { lock.withLock { active -= 1; if finishedAt == nil { finishedAt = Date() } } }  // clock starts at the first send only
        var snapshot: (sending: Bool, finishedAt: Date?) { lock.withLock { (active > 0, finishedAt) } }
    }

    private func run(emit: @escaping @Sendable (ScanEvent) -> Void) throws {
        // The NAS answers to broadcast port 9999 whatever our source port is, so we must listen there.
        // REUSEPORT lets us coexist with the OEM app.
        let fd = try Net.udpSocket(port: Packet.port)
        defer { close(fd) }

        let query = Packet.query()
        let sweep = extraSubnets.flatMap(\.hosts).map { in_addr_t(UInt32($0).bigEndian) }
        let state = SendState()
        let start = Date()
        var lastReply: Date?
        var retried = false
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 65535)

        func send() {
            state.begin()
            Thread.detachNewThread {
                sendQuery(query, fd: fd, sweep: sweep, emit: emit)
                state.end()
            }
        }
        send()

        // Sends on one thread: sweeps were measured at about 17k packets/s and extra sender threads
        // made that slower, not faster.
        defer { while state.snapshot.sending { usleep(10_000) } }  // keep the fd open until the sender is done

        while !Task.isCancelled {
            let (sending, finishedAt) = state.snapshot
            if !sending {
                let elapsed = Date().timeIntervalSince(finishedAt ?? start)
                if elapsed >= duration { break }
                if let lastReply, elapsed >= minimumDuration, Date().timeIntervalSince(lastReply) >= settleTime { break }
                if seen.isEmpty, !retried, elapsed >= retryAfter {
                    retried = true
                    send()
                }
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0, let device = SynologyDevice(datagram: Data(buffer[0..<n])) else { continue }
            lastReply = Date()
            if seen.insert(device.id).inserted { emit(.device(device)) }
        }
    }

    /// Sends to the limited broadcast address and every interface's directed broadcast address (so
    /// multi-homed Macs reach every subnet), then unicasts to each address of the extra subnets.
    private func sendQuery(_ query: Data, fd: Int32, sweep: [in_addr_t], emit: (ScanEvent) -> Void) {
        let targets = includeBroadcast ? [("all", INADDR_BROADCAST)] + Net.interfaceBroadcasts() : []
        for target in targets {
            let error = Net.send(query, fd: fd, to: target.1, port: Packet.port)
            if error != 0 { emit(.sendFailed(interface: target.0, errno: error)) }
        }
        for host in sweep { Net.send(query, fd: fd, to: host, port: Packet.port) }
    }
}
