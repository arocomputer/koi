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
    private static func binaryHash(_ url: URL) throws -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let cached = lock.withLock({ hashes[url] }), cached.modified == modified { return cached.hash }
        guard let binary = try? Data(contentsOf: url) else {
            throw Failure(description: "cannot read the server binary at \(url.path)")
        }
        let hash = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        lock.withLock { hashes[url] = (modified, hash) }
        return hash
    }
    nonisolated(unsafe) private static var hashes: [URL: (modified: Date, hash: String)] = [:] // guarded by lock

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
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1)
            if words.count == 2, words[0] == "hostname" { return String(words[1]) }
        }
        return nil
    }

    /// An SSH channel running `koi --stdio` on `host`, which relays to that
    /// machine's server.
    private static func relay(_ host: String) -> Socket? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        let theirs = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshOptions + ["-T", host, "exec \(remoteDir)/koi --stdio"]
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
    /// show them in), and one shared master connection per host.
    static var sshOptions: [String] {
        let dir = "/tmp/koi-\(getuid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ControlMaster=auto", "-o", "ControlPath=\(dir)/cm-%C", "-o", "ControlPersist=600",
                "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
    }

    /// Runs a shell command on `host` and returns its output; throws with
    /// SSH's message when it fails.
    private static func run(_ host: String, _ command: String, input: Data? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshOptions + ["-T", host, command]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        try p.run()
        if let input {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: message.isEmpty ? "ssh \(host) failed" : message)
        }
        return String(decoding: output, as: UTF8.self)
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
