import Foundation
@testable import Koi

/// Private server and transport fixtures shared by session integration checks.
final class TestServer {
    let process = Process()
    let dir: URL

    init(extraEnvironment: [String: String] = [:]) throws {
        // Foundation may resolve the system temp directory despite TMPDIR.
        // The runner's explicit root keeps crash cleanup scoped to this run.
        let temporaryRoot = ProcessInfo.processInfo.environment["KOI_TEST_ROOT"] ?? NSTemporaryDirectory()
        dir = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("koi-test-\(UUID().uuidString.prefix(8))")
        try Paths.ensurePrivateDirectory(dir)
        setenv("KOI_DIR", dir.path, 1)
        // The server under test: Koi's Zig core, or whatever KOI_SERVER_BIN names.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bin = ProcessInfo.processInfo.environment["KOI_SERVER_BIN"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("build/core/koi")
        process.executableURL = bin
        process.arguments = ["--server"]
        process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, value in value }
        try process.run()
        if ProcessInfo.processInfo.environment["KOI_TEST_ROOT"] != nil {
            do {
                try String(process.processIdentifier).write(to: dir.appendingPathComponent("server.pid"), atomically: true, encoding: .utf8)
            } catch {
                process.terminate()
                process.waitUntilExit()
                throw error
            }
        }
        for _ in 0..<200 where Socket.connect(path: Paths.socket) == nil { usleep(10_000) }
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("server.pid"))
        try? FileManager.default.removeItem(at: dir)
    }

    /// Asks the server for a UDP offer over its local socket.
    func offer() -> Wire.Offer? {
        guard let local = Socket.connect(path: Paths.socket) else { return nil }
        local.send(.offer)
        var offer: Wire.Offer?
        local.readFrames { kind, payload in
            if kind == .offered {
                offer = try? JSONDecoder().decode(Wire.Offer.self, from: Data(payload))
                local.close()
            }
        }
        return offer
    }
}

/// Polls `condition` for up to ten seconds.
private func eventually(_ condition: () -> Bool) -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        usleep(10_000)
    }
    return false
}

/// A control connection: watches the tree and runs commands.
final class TestControl: @unchecked Sendable {
    private let socket: Transport
    private let lock = NSLock()
    private var latest = Wire.State()
    private var results: [Wire.Result] = []

    convenience init?() {
        guard let s = Socket.connect(path: Paths.socket) else { return nil }
        self.init(socket: s)
    }

    init?(socket s: Transport) {
        socket = s
        s.send(.watch)
        Thread.detachNewThread { [self] in
            s.readFrames { kind, payload in
                lock.withLock {
                    switch kind {
                    case .state: latest = (try? JSONDecoder().decode(Wire.State.self, from: Data(payload))) ?? latest
                    case .result: results.append(try! JSONDecoder().decode(Wire.Result.self, from: Data(payload)))
                    default: break
                    }
                }
            }
        }
    }

    var state: Wire.State { lock.withLock { latest } }

    func run(_ command: Wire.Command) -> Wire.Result {
        let before = lock.withLock { results.count }
        socket.send(Wire.frame(.command, json: command))
        _ = eventually { lock.withLock { results.count > before } }
        return lock.withLock { results.count > before ? results[before] : Wire.Result(error: "timed out") }
    }

    func waitFor(_ condition: (Wire.State) -> Bool) -> Bool {
        eventually { condition(state) }
    }
}

/// A headless pane: attaches like the app and mirrors the pane in a
/// terminal of its own.
final class TestPane: @unchecked Sendable {
    private let socket: Transport
    private let lock = NSLock()
    private var terminal: VTTerminal?
    private var resized: GridSize?

    init?(_ pane: String, cols: UInt16 = 80, rows: UInt16 = 24, transport: Transport? = nil) {
        guard let s = transport ?? Socket.connect(path: Paths.socket) else { return nil }
        socket = s
        s.send(Wire.frame(.open, json: Wire.OpenRequest(pane: pane, cols: cols, rows: rows, cellWidth: 8, cellHeight: 16)))
        Thread.detachNewThread { [self] in
            s.readFrames { kind, payload in
                lock.withLock {
                    switch kind {
                    case .snapshot: terminal = VTTerminal(snapshot: Array(payload))
                    case .output: payload.withUnsafeBytes { terminal?.write($0) }
                    case .resized: if let size = Wire.decodeSize(payload) { terminal?.resize(size); resized = size }
                    default: break
                    }
                }
            }
        }
    }

    func type(_ text: String) { socket.send(.input, Array(text.utf8)) }
    func resize(_ size: GridSize) { socket.send(.resize, Wire.encode(size)) }

    func waitForResize(cols: UInt16, rows: UInt16) -> Bool {
        eventually { lock.withLock { resized?.cols == cols && resized?.rows == rows } }
    }
    func close() { socket.close() }

    /// The current screen as text, for tight polling.
    func visibleText() -> String { lock.withLock { terminal?.text() ?? "" } }

    func waitForText(_ text: String) -> Bool {
        eventually { lock.withLock { terminal?.text().contains(text) == true } }
    }
}
