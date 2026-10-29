import CryptoKit
import Darwin
import Foundation

/// Reaching Koi on another machine: installing it there over SSH, opening
/// the UDP link to its server, and relaying over SSH when UDP is blocked.
enum Remote {
    /// Where Koi lives on a remote machine: its one binary, as `koi`, the
    /// name the command-line tool goes by too.
    static let remoteDir = "$HOME/.local/share/koi"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var links: [String: LinkClient] = [:] // guarded by lock

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Makes sure `host` runs this Koi's server: installs or replaces its
    /// copy when it differs, by hash. Blocks; run it off the main thread.
    static func prepare(_ host: String) throws {
        let probe = try run(host, "uname -sm; test -x \(remoteDir)/koi && cat \(remoteDir)/koi.sha256 2>/dev/null || true")
        let lines = probe.split(separator: "\n").map(String.init)
        guard let system = lines.first else { throw Failure(description: "\(host) did not answer") }
        let url = try serverBinary(for: system)
        let hash = try binaryHash(url)
        if lines.dropFirst().first != hash {
            guard let binary = try? Data(contentsOf: url) else {
                throw Failure(description: "cannot read the server binary for \(system)")
            }
            _ = try run(host, """
                mkdir -p \(remoteDir) && cat > \(remoteDir)/koi.new && chmod 755 \(remoteDir)/koi.new \
                && mv -f \(remoteDir)/koi.new \(remoteDir)/koi && echo \(hash) > \(remoteDir)/koi.sha256
                """, input: binary)
        }
        openLink(host)
    }

    /// The hash a server binary is installed under, computed once per file
    /// version: hashing eight megabytes on every connection is wasted work.
    /// The key includes the size too, because a rebuilt binary can keep the
    /// old modification time (`cp -p`, a restored artifact) and would then look
    /// unchanged and never be reinstalled.
    private static func binaryHash(_ url: URL) throws -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? -1
        if let cached = lock.withLock({ hashes[url] }), cached.modified == modified, cached.size == size {
            return cached.hash
        }
        guard let binary = try? Data(contentsOf: url) else {
            throw Failure(description: "cannot read the server binary at \(url.path)")
        }
        let hash = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        lock.withLock { hashes[url] = (modified, size, hash) }
        return hash
    }
    nonisolated(unsafe) private static var hashes: [URL: (modified: Date, size: Int, hash: String)] = [:] // guarded by lock

    /// The binary that is Koi's server on a machine reporting `uname -sm`
    /// as `system`: on an Apple silicon Mac, this app's own; on Linux, the
    /// static build carried in the app's resources.
    static func serverBinary(for system: String) throws -> URL {
        switch system {
        case "Darwin arm64":
            guard let url = LocalServer.binary else { throw Failure(description: "this build of Koi has no server binary") }
            return url
        case "Linux x86_64", "Linux aarch64":
            let arch = system.split(separator: " ")[1]
            guard let url = LocalServer.binary(named: "koi-linux-\(arch)") else {
                throw Failure(description: "this build of Koi has no server for Linux \(arch)")
            }
            return url
        case let s where s.hasPrefix("Darwin"):
            throw Failure(description: "an Intel Mac; Koi is built for Apple silicon")
        default:
            throw Failure(description: "\(system) is not a system Koi runs on")
        }
    }

    /// Opens the UDP link to `host`'s server, if there is not one: asks it
    /// for an offer over SSH, then dials the port. Without an answer (UDP
    /// blocked), connections use the SSH relay instead.
    static func openLink(_ host: String) {
        if let link = lock.withLock({ links[host] }), !link.isClosed { return }
        let reply: String
        do { reply = try run(host, "exec \(remoteDir)/koi --offer") } catch {
            log("\(host): no offer: \(error)")
            return
        }
        guard let offer = try? JSONDecoder().decode(Wire.Offer.self, from: Data(reply.utf8)) else {
            log("\(host): bad offer")
            return
        }
        guard let address = address(of: host) else {
            log("\(host): no address")
            return
        }
        let secret = Wire.secretBytes(offer.secret)
        guard secret.count == 32, let link = LinkClient(host: address, port: offer.port, secret: secret) else {
            log("\(host): UDP to \(address):\(offer.port) unanswered; using the SSH relay")
            // A firewall rarely opens within minutes: each probe costs an SSH
            // round trip, so an unanswered host waits a while before the next.
            lock.withLock { nextProbe[host] = Date().addingTimeInterval(unansweredBackoff) }
            return
        }
        // Two openLink calls can race (connect's retry and prepare); the first
        // live link stays, so streams already opened on it keep their link.
        let won = lock.withLock {
            if let current = links[host], !current.isClosed { return false }
            links[host] = link
            return true
        }
        if won { log("\(host): link up to \(address):\(offer.port)") }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[koi] \(message)\n".utf8))
    }

    /// A connection to the server on `host`: a stream of its link, or,
    /// without one, a relay over SSH, while the link is tried again now and
    /// then in the background (a firewall may open, a network may change).
    static func connect(_ host: String) -> Transport? {
        if let link = lock.withLock({ links[host] }), !link.isClosed, let stream = link.open() { return stream }
        let retry = lock.withLock {
            let due = Date() >= (nextProbe[host] ?? .distantPast)
            if due { nextProbe[host] = Date().addingTimeInterval(30) }
            return due
        }
        if retry { DispatchQueue.global().async { openLink(host) } }
        return relay(host)
    }
    /// When each host's link may next be tried; an unanswered probe pushes
    /// it out by `unansweredBackoff`. Guarded by `lock`.
    nonisolated(unsafe) private static var nextProbe: [String: Date] = [:]
    private static let unansweredBackoff: TimeInterval = 10 * 60

    /// The address SSH reaches `host` at, after `~/.ssh/config`.
    private static func address(of host: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G", host]
        guard let result = try? runProcess(p) else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1)
            if words.count == 2, words[0] == "hostname" { return String(words[1]) }
        }
        return nil
    }

    /// An SSH channel running `koi --stdio` on `host`, which relays to that
    /// machine's server.
    private static func relay(_ host: String) -> Socket? {
        guard let options = try? sshOptions else { return nil }
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        let theirs = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = options + ["-T", host, "exec \(remoteDir)/koi --stdio"]
        p.standardInput = theirs
        p.standardOutput = theirs
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Darwin.close(fds[0])
            return nil
        }
        try? theirs.close()
        let socket = Socket(fd: fds[0])
        socket.onClose = { [p] in if p.isRunning { p.terminate() } }
        return socket
    }

    /// The hosts in `~/.ssh/config`, without wildcard patterns.
    static func configuredHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 2, words[0].lowercased() == "host" else { continue }
            for w in words.dropFirst() where !w.contains("*") && !w.contains("?") && !w.hasPrefix("!") {
                if !hosts.contains(String(w)) { hosts.append(String(w)) }
            }
        }
        return hosts
    }

    /// Options for every SSH Koi runs: no prompts (Koi has no terminal to
    /// show them in), and one shared master connection per host in a verified
    /// private directory. Unsafe paths fail before SSH starts.
    static var sshOptions: [String] {
        get throws {
            let dir = "/tmp/koi-\(getuid())"
            try Paths.ensurePrivateDirectory(URL(fileURLWithPath: dir))
            return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ControlMaster=auto", "-o", "ControlPath=\(dir)/cm-%C", "-o", "ControlPersist=600",
                    "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
        }
    }

    /// Runs a shell command on `host` and returns its output; throws with
    /// SSH's message when it fails.
    private static func run(_ host: String, _ command: String, input: Data? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = try sshOptions + ["-T", host, command]
        let result = try runProcess(p, input: input)
        guard p.terminationStatus == 0 else {
            let message = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: message.isEmpty ? "ssh \(host) failed" : message)
        }
        return String(decoding: result.output, as: UTF8.self)
    }

    /// Runs a disposable command on the caller's background thread. Multiplexed,
    /// nonblocking I/O bounds both streams and input lifetime; every exit reaps the child.
    static func runProcess(_ process: Process, input: Data? = nil,
                           outputLimit: Int = 1024 * 1024, timeout: TimeInterval = 60) throws
        -> (output: Data, errors: Data) {
        guard outputLimit >= 0, timeout > 0, timeout.isFinite else { throw POSIXError(.EINVAL) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
        let childInput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        defer { try? childInput.close(); Darwin.close(sockets[0]) }
        defer { try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close() }
        var noSignal: Int32 = 1
        guard setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw POSIXError(.EIO) }
        let descriptors = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor, sockets[0]]
        for fd in descriptors {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        }
        guard !Task<Never, Never>.isCancelled else { throw CancellationError() }
        process.standardInput = childInput
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try childInput.close()
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var streams = [Data(), Data()]
        var ended = [false, false]
        var sent = 0
        let input = input ?? Data()
        var inputClosed = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure(description: "Remote command timed out")
            }
            // Read each ready stream once per turn so neither can starve the other.
            for index in 0..<2 where !ended[index] {
                let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                if count > 0 {
                    guard count <= outputLimit - streams[index].count else {
                        throw Failure(description: "Remote command output exceeded its limit")
                    }
                    streams[index].append(contentsOf: buffer.prefix(count))
                } else if count == 0 { ended[index] = true }
                else if errno != EAGAIN && errno != EINTR { throw POSIXError(.EIO) }
            }
            if !inputClosed {
                if sent < input.count {
                    let count = input.withUnsafeBytes {
                        Darwin.write(sockets[0], $0.baseAddress! + sent, min(16 * 1024, input.count - sent))
                    }
                    if count > 0 { sent += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR {
                        shutdown(sockets[0], SHUT_WR)
                        inputClosed = true
                    }
                } else {
                    shutdown(sockets[0], SHUT_WR)
                    inputClosed = true
                }
            }
            if ended.allSatisfy({ $0 }) && !process.isRunning { break }
            var waiting = descriptors.enumerated().map { index, fd in
                pollfd(fd: (index < 2 && ended[index]) || (index == 2 && inputClosed) ? -1 : fd,
                       events: Int16(index < 2 ? POLLIN : POLLOUT), revents: 0)
            }
            _ = poll(&waiting, nfds_t(waiting.count), 10)
        }
        return (streams[0], streams[1])
    }
}
