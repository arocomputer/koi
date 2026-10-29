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
