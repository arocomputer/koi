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
    nonisolated(unsafe) private static var links: [String: RemoteLinkState<LinkClient>] = [:] // guarded by lock
    nonisolated(unsafe) private static var preparations: [String: NSLock] = [:] // guarded by lock

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Makes sure `host` runs this Koi's server: installs or replaces its
    /// copy when it differs, by hash. Blocks; run it off the main thread.
    static func prepare(_ host: String) throws {
        try prepare(host, serverBinary: serverBinary, run: { try run($0, $1, input: $2) }, openLink: openLink)
    }

    /// Serializes the entire probe/install/link sequence per SSH host. Injected
    /// operations let tests exercise preparation without SSH or real servers.
    static func prepare(_ host: String, serverBinary: (String) throws -> URL,
                        run: (String, String, Data?) throws -> String, openLink: (String) -> Void) throws {
        let preparation = lock.withLock {
            if let current = preparations[host] { return current }
            let current = NSLock()
            preparations[host] = current
            return current
        }
        preparation.lock()
        defer { preparation.unlock() }
        let probe = try run(host, """
            \(hashCommand)
            uname -sm
            if test -x "\(remoteDir)/koi"; then koi_hash "\(remoteDir)/koi"; fi
            """, nil)
        let lines = probe.split(separator: "\n").map(String.init)
        guard let system = lines.first else { throw Failure(description: "\(host) did not answer") }
        let url = try serverBinary(system)
        let hash = try binaryHash(url)
        if lines.dropFirst().first != hash {
            guard let binary = try? Data(contentsOf: url) else {
                throw Failure(description: "cannot read the server binary for \(system)")
            }
            _ = try run(host, """
                \(hashCommand)
                mkdir -p "\(remoteDir)" && stage=$(mktemp -d "\(remoteDir)/.install.XXXXXXXX") || exit 1
                trap 'rm -rf "$stage"' 0
                trap 'exit 1' 1 2 15
                cat > "$stage/koi" && actual=$(koi_hash "$stage/koi") || exit 1
                test "$actual" = \(hash) || { echo 'Koi upload checksum mismatch' >&2; exit 1; }
                chmod 755 "$stage/koi" && mv -f "$stage/koi" "\(remoteDir)/koi"
                """, binary)
        }
        openLink(host)
    }

    /// Hash the actual bytes on Linux or macOS. A single binary rename is the
    /// commit point: legacy sidecars and stages left by a crash are never trusted.
    private static let hashCommand = """
        koi_hash() {
            if command -v sha256sum >/dev/null 2>&1; then
                digest=$(sha256sum "$1") || return 1
            else
                digest=$(shasum -a 256 "$1") || return 1
            fi
            printf '%s\\n' "${digest%% *}"
        }
        """

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

    /// Tries one UDP probe when the host is due, including calls from prepare.
    static func openLink(_ host: String) {
        let token = lock.withLock { () -> UInt64? in
            var state = links[host] ?? RemoteLinkState()
            let token = state.beginProbe(now: ProcessInfo.processInfo.systemUptime)
            links[host] = state
            return token
        }
        guard let token else { return }
        defer { lock.withLock { links[host]?.endProbe(token) } }
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
            lock.withLock { links[host]?.probeUnanswered(token, now: ProcessInfo.processInfo.systemUptime) }
            return
        }
        let won = lock.withLock { links[host]?.install(link, token: token) ?? false }
        if won { log("\(host): link up to \(address):\(offer.port)") }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[koi] \(message)\n".utf8))
    }

    /// Opens a cached link stream or uses SSH while a UDP probe is due.
    static func connect(_ host: String) -> Transport? {
        let (stream, retired): (LinkStream?, LinkClient?) = lock.withLock {
            guard let link = links[host]?.owner else { return (nil, nil) }
            if !link.isClosed {
                if let stream = link.open() { return (stream, nil) }
                if !link.isClosed { return (nil, nil) }
            }
            links[host]?.quarantine(link, now: ProcessInfo.processInfo.systemUptime)
            return (nil, link)
        }
        withExtendedLifetime(retired) {}
        if let stream { return stream }
        DispatchQueue.global().async { openLink(host) }
        return relay(host)
    }

    /// Reports an attach or handshake failure without closing other streams.
    static func connectionFailed(_ endpoint: Endpoint, transport: Transport) {
        guard case .ssh(let host) = endpoint, let stream = transport as? LinkStream else { return }
        quarantine(host, owner: stream.owner)
    }

    /// Removes only the failed owner; its streams retain it until they finish.
    private static func quarantine(_ host: String, owner: LinkClient) {
        lock.withLock {
            links[host]?.quarantine(owner, now: ProcessInfo.processInfo.systemUptime)
        }
        // `owner` stays retained through the lock, so native destruction cannot
        // wait for link workers while holding the cache lock.
        withExtendedLifetime(owner) {}
    }

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

    /// How often a keepalive crosses each SSH connection. Mirrors
    /// `keepalive_interval_ms` in src/core/remote.zig, whose relay drops a
    /// connection that goes quiet for longer than three of these once it has
    /// seen one. Without that, a laptop that sleeps or loses its network leaves
    /// a relay and a server connection behind on the other machine for good.
    private static let keepaliveInterval: TimeInterval = 20

    /// An SSH channel running `koi --stdio` on `host`, which relays to that
    /// machine's server. The remote copy is the one `prepare` installed from
    /// this app, so it understands the keepalive frames sent over the channel.
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
        let beat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        beat.schedule(deadline: .now() + keepaliveInterval, repeating: keepaliveInterval)
        beat.setEventHandler { [weak socket] in socket?.send(.keepalive) }
        beat.resume()
        socket.onClose = { [p] in
            beat.cancel()
            if p.isRunning { p.terminate() }
        }
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
        // Uploading the server binary can take minutes on a slow uplink: allow
        // 32 KB/s (about 256 kbit/s) for the input on top of the base deadline.
        let result = try runProcess(p, input: input, timeout: 60 + Double(input?.count ?? 0) / 32_000)
        guard p.terminationStatus == 0 else {
            let message = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: message.isEmpty ? "ssh \(host) failed" : message)
        }
        return String(decoding: result.output, as: UTF8.self)
    }

    /// Runs a disposable command on the caller's background thread. Multiplexed,
    /// nonblocking I/O bounds each stream and input lifetime; every exit reaps the child.
    /// Successful commands must accept all input; failed commands retain their stderr.
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
        defer { try? childInput.close(); if sockets[0] >= 0 { Darwin.close(sockets[0]) } }
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
        // Ends the child's input. Shutting down the write side is not enough: on
        // macOS a child blocked reading the other end of a socketpair was seen,
        // about once in 500 commands run at the same time, never to wake for it
        // and to wait for an end of file that had already been sent. Closing our
        // end as well always did, so a command that reads its input to the end
        // (the upload's `cat`) cannot hang until the deadline.
        func closeInput() {
            shutdown(sockets[0], SHUT_WR)
            Darwin.close(sockets[0])
            sockets[0] = -1
            inputClosed = true
        }
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
                    else if count < 0 && errno != EAGAIN && errno != EINTR { closeInput() }
                } else {
                    closeInput()
                }
            }
            if ended.allSatisfy({ $0 }) && !process.isRunning { break }
            var waiting = descriptors.enumerated().map { index, fd in
                pollfd(fd: (index < 2 && ended[index]) || (index == 2 && inputClosed) ? -1 : fd,
                       events: Int16(index < 2 ? POLLIN : POLLOUT), revents: 0)
            }
            _ = poll(&waiting, nfds_t(waiting.count), 10)
        }
        if sent < input.count, process.terminationStatus == 0 {
            throw Failure(description: "Remote command closed input before upload completed")
        }
        return (streams[0], streams[1])
    }
}

/// Per-host cache and probe policy. Callers serialize access and retain a
/// removed owner until after releasing their lock.
struct RemoteLinkState<Owner: AnyObject> {
    private(set) var owner: Owner?
    private(set) var nextProbe: TimeInterval = 0
    private var generation: UInt64 = 0
    private var probing = false

    mutating func beginProbe(now: TimeInterval) -> UInt64? {
        guard owner == nil, !probing, now >= nextProbe else { return nil }
        probing = true
        nextProbe = now + 30
        generation &+= 1
        return generation
    }

    mutating func endProbe(_ token: UInt64) {
        if token == generation { probing = false }
    }

    mutating func probeUnanswered(_ token: UInt64, now: TimeInterval) {
        if token == generation { nextProbe = now + 10 * 60 }
    }

    mutating func install(_ candidate: Owner, token: UInt64) -> Bool {
        guard probing, token == generation, owner == nil else { return false }
        owner = candidate
        return true
    }

    mutating func quarantine(_ failed: Owner, now: TimeInterval) {
        guard owner === failed else { return }
        owner = nil
        nextProbe = now + 30
        generation &+= 1
        probing = false
    }
}
