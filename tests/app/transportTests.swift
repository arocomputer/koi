import Foundation
import Testing
@testable import Koi

@Suite struct SocketTests {
    /// Kernel credentials must work on private socket pairs and fail on invalid fds.
    @Test func localPeerIdentityFailsClosed() {
        let (a, b) = pair()
        defer { Darwin.close(a); Darwin.close(b) }
        #expect(Socket.sameUserPeer(a))
        #expect(Socket.sameUserPeer(b))
        #expect(!Socket.sameUserPeer(-1))
    }

    /// Existing public directories and symlinked leaves are rejected without repairing them.
    @Test func privateDirectoriesRejectUnsafeModesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koi-private-\(UUID().uuidString)")
        try Paths.ensurePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try Paths.ensurePrivateDirectory(child)
        try Paths.ensurePrivateDirectory(child)
        #expect(chmod(child.path, 0o755) == 0)
        #expect(throws: (any Error).self) { try Paths.ensurePrivateDirectory(child) }
        var info = stat()
        #expect(lstat(child.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o755)
        let link = root.appendingPathComponent("link")
        #expect(symlink(child.path, link.path) == 0)
        #expect(throws: (any Error).self) { try Paths.ensurePrivateDirectory(link) }
        // A symlinked ancestor is followed and its target checked like any other.
        try Paths.ensurePrivateDirectory(link.appendingPathComponent("nested"))
        #expect(rmdir(child.appendingPathComponent("nested").path) == 0)
        #expect(chmod(child.path, 0o757) == 0)
        #expect(throws: (any Error).self) { try Paths.ensurePrivateDirectory(link.appendingPathComponent("nested")) }
        #expect(chmod(child.path, 0o755) == 0)
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try Paths.ensurePrivateDirectory(file.appendingPathComponent("nested")) }
    }

    /// A real local connect authenticates its peer and refuses public socket directories.
    @Test func localConnectRequiresPrivateDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("koi-socket-\(UUID().uuidString)")
        try Paths.ensurePrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("server.sock").path
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_un.make(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        let connection = try #require(Socket.connect(path: path))
        connection.close()
        #expect(chmod(root.path, 0o755) == 0)
        #expect(Socket.connect(path: path) == nil)
    }

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

    /// The queue is bounded in writes as well as bytes: a peer that stops reading
    /// while thousands of tiny writes pile up must not make closures pile up too.
    @Test func tinyWritesOverflowTheQueue() {
        let (a, b) = pair()
        defer { Darwin.close(b) }
        let socket = Socket(fd: a, maxQueued: 1 << 30)
        let closed = DispatchSemaphore(value: 0)
        socket.onClose = { closed.signal() }
        socket.send([UInt8](repeating: 1, count: 256 * 1024)) // jams the small kernel buffer
        for _ in 0..<5000 { socket.send([0]) }
        #expect(closed.wait(timeout: .now() + 5) == .success)
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

@Suite struct RemoteLinkPolicyTests {
    private final class Owner {}

    @Test func failureQuarantinesOnlyTheMatchingOwnerForThirtySeconds() {
        var state = RemoteLinkState<Owner>()
        let first = Owner(), other = Owner()
        let token = state.beginProbe(now: 100)!
        let installed = state.install(first, token: token)
        #expect(installed)
        state.endProbe(token)
        state.quarantine(other, now: 101)
        #expect(state.owner === first)
        state.quarantine(first, now: 102)
        #expect(state.owner == nil)
        #expect(state.beginProbe(now: 131) == nil)
        let retry = state.beginProbe(now: 132)!
        let reinstalled = state.install(other, token: retry)
        #expect(reinstalled)
        state.endProbe(retry)
        state.quarantine(first, now: 133)
        #expect(state.owner === other)
    }

    @Test func staleProbeCannotReinstallOrChangeCooldownAfterFailure() {
        var state = RemoteLinkState<Owner>()
        let first = Owner(), replacement = Owner()
        let token = state.beginProbe(now: 10)!
        let installed = state.install(first, token: token)
        #expect(installed)
        state.quarantine(first, now: 11)
        let staleInstalled = state.install(replacement, token: token)
        #expect(!staleInstalled)
        state.probeUnanswered(token, now: 12)
        state.endProbe(token)
        #expect(state.beginProbe(now: 40) == nil)
        #expect(state.beginProbe(now: 41) != nil)
    }

    @Test func probesAreSingleAndUnansweredProbesBackOff() {
        var state = RemoteLinkState<Owner>()
        let token = state.beginProbe(now: 10)!
        #expect(state.beginProbe(now: 50) == nil)
        state.probeUnanswered(token, now: 12)
        state.endProbe(token)
        #expect(state.beginProbe(now: 611) == nil)
        #expect(state.beginProbe(now: 612) != nil)
    }
}
