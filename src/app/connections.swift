import Foundation

/// One pane's connection to the server. Events arrive on a reader thread and
/// are handed to `onEvents` on the main thread in batches, in order, so a
/// burst of output costs one main-thread hop, not one per read.
final class PaneConnection: @unchecked Sendable {
    enum Event {
        case attached(Wire.PaneInfo)
        case snapshot([UInt8])
        case output(ArraySlice<UInt8>)
        case resized(GridSize)
        case exited(Int32)
        case disconnected
    }

    private let socket: Transport
    private let lock = NSCondition()
    private var pending: [Event] = []
    private var pendingBytes = 0
    private var scheduled = false
    private var closed = false
    @MainActor var onEvents: (([Event]) -> Void)?

    /// Connects to the endpoint's server (starting it if needed) and attaches
    /// to `request.pane`; nil if the server is out of reach.
    @MainActor convenience init?(_ request: Wire.OpenRequest, at endpoint: Endpoint) {
        guard let socket = endpoint.connect() else { return nil }
        self.init(request, socket: socket)
    }

    /// Attaches through an owned transport; delivery stays on the main actor.
    @MainActor init(_ request: Wire.OpenRequest, socket: Transport) {
        self.socket = socket
        socket.send(Wire.frame(.open, json: request))
        Thread.detachNewThread { [self] in
            socket.readFrames { kind, payload in
                switch kind {
                case .attached:
                    if let info = try? JSONDecoder().decode(Wire.PaneInfo.self, from: Data(payload)) {
                        post(.attached(info))
                    }
                case .snapshot: post(.snapshot(Array(payload)))
                // A short slice must not pin a large frame-reader allocation.
                case .output: post(.output(Array(payload)[...]))
                case .resized: if let s = Wire.decodeSize(payload) { post(.resized(s)) }
                case .exited:
                    let code = payload.count == 4 ? payload.reversed().reduce(Int32(0)) { $0 << 8 | Int32($1) } : 0
                    post(.exited(code))
                default: break
                }
            }
            post(.disconnected)
        }
    }

    func send(input bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        socket.send(.input, bytes)
    }

    func send(resize size: GridSize) {
        socket.send(.resize, Wire.encode(size))
    }

    /// Ends the pane's shell with SIGHUP.
    func kill() {
        socket.send(.kill)
    }

    func close() {
        lock.lock()
        closed = true
        pending.removeAll()
        pendingBytes = 0
        lock.broadcast()
        lock.unlock()
        socket.close()
    }

    private func post(_ event: Event) {
        let bytes: Int = switch event {
        case .snapshot(let data): data.count
        case .output(let data): data.count
        case .attached(let info):
            // Charge owned metadata too; a long program-supplied title must
            // not bypass the pending-byte limit.
            info.id.utf8.count + info.title.utf8.count + info.cwd.utf8.count
                + (info.home?.utf8.count ?? 0) + info.program.utf8.count + info.shell.utf8.count + 256
        default: 256
        }
        lock.lock()
        // Pause the reader, letting socket/link flow control take over. A
        // single large snapshot is allowed when the batch is otherwise empty.
        while !closed && !pending.isEmpty && (pendingBytes + bytes > 8 * 1024 * 1024 || pending.count >= 1024) {
            lock.wait()
        }
        guard !closed else { lock.unlock(); return }
        pending.append(event)
        pendingBytes += bytes
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let events = pending
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            scheduled = false
            lock.broadcast()
            lock.unlock()
            MainActor.assumeIsolated { if !events.isEmpty { onEvents?(events) } }
        }
    }
}

/// The app's control connection: it watches the server's tree and sends it
/// commands. `onState` and command completions run on the main thread.
final class Control: @unchecked Sendable {
    private let socket: Transport
    /// The actual selected stream, rather than the server's advertised transports.
    var usesEncryptedLink: Bool { socket is LinkStream }
    private let lock = NSLock()
    /// Completions for commands sent and not yet answered; the server answers
    /// a connection's commands in order.
    private var waiting: [@MainActor (Wire.Result) -> Void] = []
    private var latestState: Wire.State?
    private var stateScheduled = false
    private var closed = false
    @MainActor var onState: ((Wire.State) -> Void)?
    @MainActor var onDisconnect: (() -> Void)?

    @MainActor convenience init?(_ endpoint: Endpoint) {
        guard let socket = endpoint.connect() else { return nil }
        self.init(socket: socket)
    }

    /// The UI acquires transports off the main actor, then installs the
    /// watcher here before any queued main-actor state delivery can run.
    @MainActor init(socket: Transport) {
        self.socket = socket
        socket.send(.watch)
        Thread.detachNewThread { [self] in
            socket.readFrames { kind, payload in
                switch kind {
                case .state:
                    guard let state = try? JSONDecoder().decode(Wire.State.self, from: Data(payload)) else { return }
                    postState(state)
                case .result:
                    let result = (try? JSONDecoder().decode(Wire.Result.self, from: Data(payload))) ?? Wire.Result(error: "malformed result")
                    let done = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
                    if let done { DispatchQueue.main.async { done(result) } }
                default: break
                }
            }
            finish(disconnected: true)
        }
    }

    func send(_ command: Wire.Command, done: @escaping @MainActor (Wire.Result) -> Void = { _ in }) {
        let accepted = lock.withLock {
            guard !closed, waiting.count < 4096 else { return false }
            waiting.append(done)
            // Commands and their completion slots must enter the transport
            // in the same order, including concurrent callers.
            socket.send(Wire.frame(.command, json: command))
            return true
        }
        guard accepted else { DispatchQueue.main.async { done(.init(error: "connection unavailable")) }; return }
    }

    func close() { finish(disconnected: false); socket.close() }

    /// Only the latest full tree is useful while the main actor is busy.
    private func postState(_ state: Wire.State) {
        let schedule = lock.withLock {
            guard !closed else { return false }
            latestState = state
            guard !stateScheduled else { return false }
            stateScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let state = lock.withLock {
                defer { latestState = nil; stateScheduled = false }
                return latestState
            }
            MainActor.assumeIsolated { if let state { onState?(state) } }
        }
    }

    /// Release command callbacks on close instead of retaining their owners
    /// indefinitely when a server cannot answer.
    private func finish(disconnected: Bool) {
        let callbacks: [@MainActor (Wire.Result) -> Void]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            latestState = nil
            defer { waiting.removeAll() }
            return waiting
        }
        guard let callbacks else { return }
        DispatchQueue.main.async { [self] in
            callbacks.forEach { $0(.init(error: "connection closed")) }
            MainActor.assumeIsolated { if disconnected { onDisconnect?() } }
        }
    }
}
