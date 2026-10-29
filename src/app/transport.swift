import CKoi
import Darwin
import Foundation

/// A connection carrying frames: a local socket, or a stream of a link to
/// another machine. Reads block the calling thread; writes queue, up to a
/// bound, and a peer that falls too far behind is disconnected.
protocol Transport: AnyObject, Sendable {
    /// Monotonic received-byte count, including partial frames during initialization.
    var receivedBytes: UInt64 { get }
    func send(_ bytes: [UInt8])
    /// Reads frames until the peer closes or breaks the protocol, calling
    /// `handle` for each on the calling thread.
    func readFrames(_ handle: (Wire.Kind, ArraySlice<UInt8>) -> Void)
    func close()
}

extension Transport {
    var receivedBytes: UInt64 { 0 }
    func send(_ kind: Wire.Kind, _ payload: some Collection<UInt8> = [UInt8]()) {
        send(Wire.frame(kind, payload))
    }
}

/// A connected unix socket: blocking reads on whatever thread calls
/// `readFrames`, and writes that never block their caller (they queue, in
/// order, up to a bound of bytes; past that the peer is too slow and the
/// socket closes).
///
/// `close()` shuts the connection down at once, which wakes any blocked read
/// or write, and drops what is still queued. The descriptor itself is closed
/// only when the last reference goes (queued writes and `readFrames` hold
/// one), so it is never reused while something may still touch it.
final class Socket: Transport, @unchecked Sendable {
    /// Bytes that may wait to be written: room for a 32 MiB snapshot and a
    /// 32 MiB paste at once.
    static let defaultMaxQueued = 128 * 1024 * 1024

    let fd: Int32
    private let maxQueued: Int
    private let writes = DispatchQueue(label: "koi.socket.write")
    private let lock = NSLock()
    private var closed = false
    private var bytesRead: UInt64 = 0
    var receivedBytes: UInt64 { lock.withLock { bytesRead } }
    private var queued = 0
    private var queuedWrites = 0
    /// Runs once the socket is closed, as for ending the SSH process that
    /// carries a remote connection.
    var onClose: (@Sendable () -> Void)?

    init(fd: Int32, maxQueued: Int = Socket.defaultMaxQueued) {
        self.fd = fd
        self.maxQueued = maxQueued
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Elsewhere, the server and the relay ignore SIGPIPE.
    }

    deinit { Darwin.close(fd) }

    /// Connects to the socket at `path`; nil if nothing listens there.
    static func connect(path: String) -> Socket? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un.make(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        return Socket(fd: fd)
    }

    /// Queues bytes to write; dropped once the socket is closed. Closes the
    /// socket instead if the queue would pass its bound.
    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let accepted = lock.withLock {
            guard !closed else { return false }
            // Bound closure overhead too: many tiny writes must not bypass
            // the byte budget while a peer has stopped reading.
            guard queuedWrites < 4096, bytes.count <= maxQueued - queued else { return false }
            queued += bytes.count
            queuedWrites += 1
            // Serialize admission and scheduling so concurrent callers cannot
            // reverse the order in which their writes enter the queue.
            writes.async { [self] in
                defer { lock.withLock { queued -= bytes.count; queuedWrites -= 1 } }
                var off = 0
                while off < bytes.count {
                    guard !lock.withLock({ closed }) else { return }
                    let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { close(); return }
                }
            }
            return true
        }
        guard accepted else { close(); return }
    }

    func readFrames(_ handle: (Wire.Kind, ArraySlice<UInt8>) -> Void) {
        var reader = FrameReader()
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            lock.withLock { bytesRead &+= UInt64(n) }
            buf.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            do {
                while let (kind, payload) = try reader.next() { handle(kind, payload) }
            } catch { break }
        }
        close()
    }

    /// Closes the connection once, now: blocked reads and writes return and
    /// queued bytes are dropped.
    func close() {
        let callback: (@Sendable () -> Void)?? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { onClose = nil }
            return .some(onClose)
        }
        guard let callback else { return }
        shutdown(fd, SHUT_RDWR)
        callback?()
    }
}

extension sockaddr_un {
    static func make(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let bytes = Array(path.utf8.prefix(dst.count - 1))
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        return addr
    }
}

/// The link to a machine, from libkoi: one encrypted UDP connection
/// carrying a stream per connection to that machine's server.
final class LinkClient: @unchecked Sendable {
    private let raw: OpaquePointer
    /// Native sends acquire the link mutex and may encrypt other streams'
    /// queued output. Keep that work off the AppKit input thread.
    fileprivate let writes = DispatchQueue(label: "koi.link.write", qos: .userInitiated)

    init?(host: String, port: UInt16, secret: [UInt8]) {
        guard secret.count == 32, let p = secret.withUnsafeBufferPointer({ koi_link_connect(host, port, $0.baseAddress) }) else { return nil }
        raw = p
    }

    deinit {
        koi_link_close(raw)
        koi_link_destroy(raw)
    }

    var isClosed: Bool { koi_link_closed(raw) != 0 }

    /// Opens a stream that keeps this client alive: destroying the link
    /// frees every native stream, so none may outlive its owner.
    func open() -> LinkStream? {
        guard let s = koi_link_open(raw) else { return nil }
        return LinkStream(s, owner: self)
    }
}

/// One stream of a link: a connection to the server there, read and written
/// like a socket. It holds its `LinkClient` strongly, so the native stream
/// stays valid for as long as anyone can use it.
final class LinkStream: Transport, @unchecked Sendable {
    private let progressLock = NSLock()
    private var bytesRead: UInt64 = 0
    var receivedBytes: UInt64 { progressLock.withLock { bytesRead } }
    private let raw: OpaquePointer
    let owner: LinkClient
    private let lock = NSLock()
    private var closed = false
    private var queued = 0
    private var queuedWrites = 0

    fileprivate init(_ raw: OpaquePointer, owner: LinkClient) {
        self.raw = raw
        self.owner = owner
    }

    /// ARC releases the native application's ownership only after readers,
    /// writers and callers have let go of this wrapper. Closing alone must
    /// keep the pointer valid for a concurrent reader or repeated close.
    deinit { koi_stream_release(raw) }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let accepted = lock.withLock {
            guard !closed, queuedWrites < 4096, bytes.count <= 64 * 1024 * 1024 - queued else { return false }
            queued += bytes.count
            queuedWrites += 1
            owner.writes.async { [self] in
                defer { lock.withLock { queued -= bytes.count; queuedWrites -= 1 } }
                guard !lock.withLock({ closed }) else { return }
                bytes.withUnsafeBufferPointer { koi_stream_send(raw, $0.baseAddress, $0.count) }
            }
            return true
        }
        if !accepted { close() }
    }

    func readFrames(_ handle: (Wire.Kind, ArraySlice<UInt8>) -> Void) {
        var reader = FrameReader()
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { koi_stream_read(raw, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            progressLock.withLock { bytesRead &+= UInt64(n) }
            buf.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            do {
                while let (kind, payload) = try reader.next() { handle(kind, payload) }
            } catch { break }
        }
        close()
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            // Queued sends observe closed and discard their bytes; this owner
            // remains alive until the worker has woken its native reader.
            owner.writes.async { [self] in koi_stream_close(raw) }
        }
    }
}
