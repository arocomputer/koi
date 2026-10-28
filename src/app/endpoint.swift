import Darwin
import Foundation
import Network

/// Wakes reconnect attempts when what they wait for changes, rather than
/// leaving them to a timer: the local server's socket appearing in its
/// runtime directory, or a network path change for remote machines. The
/// timers stay only as a bound.
@MainActor enum Reconnect {
    private static var handlers: [UUID: @MainActor () -> Void] = [:]
    private static var directoryWatch: DispatchSourceFileSystemObject?
    private static var pathMonitor: NWPathMonitor?

    /// Calls `handler` whenever a server may have become reachable, until
    /// `stopObserving` is called with the returned token.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        handlers[token] = handler
        start()
        return token
    }

    static func stopObserving(_ token: UUID) { handlers[token] = nil }

    /// Watch the socket directory as it is now; it moves only when `KOI_DIR`
    /// changes, which test fixtures do.
    static func rewatch() {
        directoryWatch?.cancel()
        directoryWatch = nil
        if !handlers.isEmpty { start() }
    }

    private static func start() {
        if directoryWatch == nil {
            let directory = (Paths.socket as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let fd = open(directory, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
                source.setEventHandler { MainActor.assumeIsolated { fire() } }
                source.setCancelHandler { close(fd) }
                source.resume()
                directoryWatch = source
            }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { fire() } } }
            monitor.start(queue: .global(qos: .utility))
            pathMonitor = monitor
        }
    }

    private static func fire() { for handler in handlers.values { handler() } }
}

/// Where a Koi server is: this Mac's, or another machine's. Another machine
/// is reached over Koi's own encrypted UDP link (see `LinkClient`), set up through
/// the user's own OpenSSH (keys, `~/.ssh/config`, ProxyJump and host trust
/// all stay SSH's); when UDP cannot get through, connections fall back to a
/// relay over an SSH channel.
enum Endpoint: Hashable, Codable, Sendable {
    case local
    /// A host as `ssh` knows it: an alias from `~/.ssh/config`, or
    /// `user@host`.
    case ssh(String)

    /// A connection to the endpoint's server, starting it if needed; nil if
    /// it cannot be reached.
    func connect() -> Transport? {
        switch self {
        case .local: LocalServer.connect()
        case .ssh(let host): Remote.connect(host)
        }
    }

    /// Socket startup, SSH and local-server retries may block. UI callers
    /// acquire the transport here, then install their callbacks on the main actor.
    func connectAsync() async -> Transport? {
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as Transport? }
            return connect()
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

/// This Mac's server: the `koi` binary the app carries, started on demand
/// and left running when the app quits.
enum LocalServer {
    private static let startup = NSLock()
    /// Connects to the server, starting one if none runs; nil if it could
    /// not be reached.
    static func connect() -> Socket? {
        guard !Task.isCancelled else { return nil }
        if let s = Socket.connect(path: Paths.socket) { return s }
        startup.lock()
        defer { startup.unlock() }
        guard !Task.isCancelled else { return nil }
        if let s = Socket.connect(path: Paths.socket) { return s }
        start()
        for _ in 0..<100 {
            guard !Task.isCancelled else { return nil }
            if let s = Socket.connect(path: Paths.socket) { return s }
            usleep(20_000)
        }
        return nil
    }

    /// The `koi` binary for this Mac: in the app's resources, or, when run
    /// from the package (tests, `swift run`), the core's build.
    static var binary: URL? { binary(named: "koi") }

    /// The version the bundled server binary reports for itself, read once
    /// by running it; nil until read or without a binary. Compared with a
    /// running server's version to tell when that server predates this app.
    nonisolated(unsafe) private(set) static var bundledVersion: String?

    /// Runs the bundled binary's `version` command. Blocks; call off the main thread.
    static func readBundledVersion() {
        guard let exe = binary else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { return }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { bundledVersion = version }
    }

    static func binary(named name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Paths.repoRoot?.appendingPathComponent("zig-out/bin/\(name)"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func start() {
        guard let exe = binary else { return }
        try? Paths.ensureDirs()
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--server"]
        p.standardInput = FileHandle.nullDevice
        let logPath = Paths.serverLog.path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }
        try? p.run()
    }
}
