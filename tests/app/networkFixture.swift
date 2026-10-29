import Darwin
import Foundation

/// Test-only loopback relay. All socket state belongs to one queue; impairment
/// applies independently in each direction, including handshake and retries.
final class NetworkFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "koi.test.network")
    private let front: Int32
    private var back: Int32
    private var server: sockaddr_in
    private var client: sockaddr_in?
    private var timer: DispatchSourceTimer?
    private var sequence = [0, 0]
    private var pending: [(due: UInt64, data: [UInt8], upstream: Bool)] = []
    private var dropped = 0
    private var forwarded = 0
    let port: UInt16

    /// Binds only ephemeral loopback sockets; never changes host networking.
    init(serverPort: UInt16) throws {
        front = try Self.socket()
        do { back = try Self.socket() } catch { Darwin.close(front); throw error }
        server = Self.address(serverPort)
        port = Self.port(front)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    /// Changes the NAT-facing source port while preserving the client's endpoint.
    /// Bind before closing so the OS cannot choose the previous port again.
    func rebind() throws -> (UInt16, UInt16) {
        try queue.sync {
            let replacement = try Self.socket()
            let old = Self.port(back)
            Darwin.close(back)
            back = replacement
            return (old, Self.port(back))
        }
    }

    var counts: (dropped: Int, forwarded: Int) { queue.sync { (dropped, forwarded) } }

    /// Cancels delivery and closes sockets after any active timer handler finishes.
    func stop() {
        queue.sync {
            guard timer != nil else { return }
            timer?.cancel()
            timer = nil
            pending.removeAll()
            Darwin.close(front)
            Darwin.close(back)
        }
    }

    deinit { stop() }

    /// Polling is nonblocking and work per tick is capped even under a noisy peer.
    private func tick() {
        guard timer != nil else { return }
        for direction in 0..<2 {
            for _ in 0..<128 {
                var peer = sockaddr_in()
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                var bytes = [UInt8](repeating: 0, count: 65536)
                let n = withUnsafeMutablePointer(to: &peer) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(direction == 0 ? front : back, &bytes, bytes.count, 0, $0, &size)
                    }
                }
                guard n >= 0 else { break }
                if direction == 0 { client = peer }
                sequence[direction] += 1
                let index = sequence[direction]
                // Fixed 1-in-11 loss and 12/20/28 ms one-way delay. Jitter
                // can reorder datagrams; the encrypted reliable stream must cope.
                if index % 11 == 0 { dropped += 1; continue }
                pending.append((DispatchTime.now().uptimeNanoseconds + UInt64(12 + index % 3 * 8) * 1_000_000,
                                Array(bytes.prefix(n)), direction == 0))
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        var waiting: [(due: UInt64, data: [UInt8], upstream: Bool)] = []
        for packet in pending {
            guard packet.due <= now else { waiting.append(packet); continue }
            guard var destination = packet.upstream ? server : client else { continue }
            let sent = withUnsafePointer(to: &destination) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    packet.data.withUnsafeBytes {
                        sendto(packet.upstream ? back : front, $0.baseAddress, $0.count, 0,
                               address, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == packet.data.count { forwarded += 1 }
        }
        pending = waiting
    }

    /// Creates a nonblocking ephemeral UDP endpoint confined to IPv4 loopback.
    private static func socket() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = address(0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        return fd
    }

    /// Builds an IPv4 loopback address in network byte order.
    private static func address(_ port: UInt16) -> sockaddr_in {
        var result = sockaddr_in()
        result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        result.sin_family = sa_family_t(AF_INET)
        result.sin_port = port.bigEndian
        result.sin_addr.s_addr = inet_addr("127.0.0.1")
        return result
    }

    /// Reads the port assigned by the kernel after an ephemeral bind.
    private static func port(_ fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        precondition(result == 0)
        return UInt16(bigEndian: address.sin_port)
    }
}
