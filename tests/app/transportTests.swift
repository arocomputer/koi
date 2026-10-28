import Foundation
import Testing
@testable import Koi

@Suite struct SocketTests {
    /// A connected pair with small kernel buffers, so a peer that never reads
    /// stalls the writer after a few KiB.
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        for fd in fds {
            var size: Int32 = 4096
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return (fds[0], fds[1])
    }

    /// A write blocked on a peer that never reads must not delay `close`: the
    /// reader is woken and the peer sees the end of the stream.
    @Test func closeWakesBlockedWriteAndRead() {
        let (a, b) = pair()
        defer { Darwin.close(b) }
        let socket = Socket(fd: a)
        let closed = DispatchSemaphore(value: 0)
        socket.onClose = { closed.signal() }
        let readerDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            socket.readFrames { _, _ in }
            readerDone.signal()
        }
        socket.send([UInt8](repeating: 1, count: 1 << 20))
        Thread.sleep(forTimeInterval: 0.05) // let the writer fill the buffers and block
        socket.close()
        #expect(closed.wait(timeout: .now() + 2) == .success)
        #expect(readerDone.wait(timeout: .now() + 2) == .success)
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var n: Int
        repeat { n = buf.withUnsafeMutableBytes { Darwin.read(b, $0.baseAddress, $0.count) } } while n > 0
        #expect(n == 0)
    }

    @Test func overflowingTheQueueClosesTheSocket() {
        let (a, b) = pair()
        defer { Darwin.close(b) }
        let socket = Socket(fd: a, maxQueued: 1 << 20)
        let closed = DispatchSemaphore(value: 0)
        socket.onClose = { closed.signal() }
        let chunk = [UInt8](repeating: 2, count: 400 * 1024)
        for _ in 0..<10 { socket.send(chunk) }
        #expect(closed.wait(timeout: .now() + 2) == .success)
    }

    @Test func sendsArriveInOrder() {
        let (a, b) = pair()
        defer { Darwin.close(b) }
        let socket = Socket(fd: a)
        let parts = (0..<50).map { [UInt8](repeating: UInt8($0), count: 1000) }
        for p in parts { socket.send(p) }
        var got = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 8192)
        while got.count < 50_000 {
            let n = buf.withUnsafeMutableBytes { Darwin.read(b, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            got += buf[0..<n]
        }
        #expect(got == parts.flatMap { $0 })
        socket.close()
    }

    /// The descriptor closes with the last reference, even if `close` was
    /// never called.
    @Test func descriptorClosesWhenSocketIsReleased() {
        let (a, b) = pair()
        defer { Darwin.close(b) }
        var socket: Socket? = Socket(fd: a)
        socket?.send([1, 2, 3])
        var buf = [UInt8](repeating: 0, count: 3)
        #expect(Darwin.read(b, &buf, 3) == 3)
        socket = nil
        var tries = 0
        while fcntl(a, F_GETFD) != -1 && tries < 200 { Thread.sleep(forTimeInterval: 0.01); tries += 1 }
        #expect(fcntl(a, F_GETFD) == -1)
    }
}
