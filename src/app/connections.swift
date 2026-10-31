import Foundation

/// Initialization expires only after eight seconds without incoming bytes.
/// Partial snapshots count as progress, so slow transfers can finish.
struct ConnectionDeadline {
    private var received: UInt64 = 0
    private var progressedAt: TimeInterval
    init(now: TimeInterval) { progressedAt = now }
    mutating func stalled(receivedBytes: UInt64, now: TimeInterval) -> Bool {
        if receivedBytes != received { received = receivedBytes; progressedAt = now }
        return now - progressedAt >= 8
    }
}

/// One pane's connection to the server. Events arrive on a reader thread and
/// are handed to `onEvents` on the main thread in batches, in order, so a
/// burst coalesces reads while bounded deliveries leave time for keyboard and
/// display events between batches.
final class PaneConnection: @unchecked Sendable {
    enum Event {
        case attached(Wire.PaneInfo)
        case snapshot([UInt8])
        case output(ArraySlice<UInt8>)
        case resized(GridSize)
        case exited(Int32)
        case disconnected
        case negotiated(ownership: Bool, observing: Bool)
        case ownership(Bool)
        case failure(String)

        /// Charge owned payloads and event overhead to the pending budget.
        var byteCount: Int {
            switch self {
            case .snapshot(let data): return data.count
            case .output(let data): return data.count
            case .attached(let info):
                let identityBytes = info.id.utf8.count + info.title.utf8.count
                let directoryBytes = info.cwd.utf8.count + (info.home?.utf8.count ?? 0)
                let programBytes = info.program.utf8.count + info.shell.utf8.count
                return identityBytes + directoryBytes + programBytes + 256
            case .failure(let message): return message.utf8.count + 256
            default: return 256
            }
        }
    }

    private let socket: Transport
    var receivedBytes: UInt64 { socket.receivedBytes }
    /// Whether this pane travels the encrypted UDP link rather than a local
    /// socket or the SSH relay.
    var usesEncryptedLink: Bool { socket is LinkStream }
    private let lock = NSCondition()
    private var pending: [Event] = []
    private var pendingBytes = 0
    private var scheduled = false
    private var closed = false
    private var inputAllowed = false
    private var ownershipSupported = false
    private var opened = false
    /// Explicit choices override defaults even before server information arrives.
    private var observationChoice: Bool?
    /// Input and ownership state are safe to inspect from any thread.
    var allowsInput: Bool { lock.withLock { !closed && inputAllowed } }
    var supportsOwnership: Bool { lock.withLock { !closed && ownershipSupported } }
    @MainActor var onEvents: (([Event]) -> Void)?

    /// Connects to the endpoint's server (starting it if needed) and attaches
    /// to `request.pane`; nil if the server is out of reach.
    @MainActor convenience init?(_ request: Wire.OpenRequest, at endpoint: Endpoint) {
        guard let socket = endpoint.connect() else { return nil }
        self.init(request, socket: socket, observer: Paths.isDev && endpoint != .local,
                  legacyObserver: endpoint != .local, negotiate: true)
    }

    /// Negotiates on the owned stream before attaching when requested.
    @MainActor init(_ request: Wire.OpenRequest, socket: Transport, observer: Bool = false,
                    legacyObserver: Bool = false, negotiate: Bool = false) {
        self.socket = socket
        inputAllowed = !negotiate
        opened = !negotiate
        if negotiate {
            socket.send(Wire.frame(.command, json: Wire.Command(op: .serverInfo)))
        } else {
            socket.send(Wire.frame(.open, json: request))
        }
        Thread.detachNewThread { [self] in
            var preflight = negotiate
            var attached = false
            var snapshot = false
            var failed = false
            socket.readFrames { kind, payload in
                guard !failed, !lock.withLock({ closed }) else { return }
                func fail(_ message: String) {
                    failed = true
                    lock.withLock { inputAllowed = false }
                    post(.failure(message))
                    socket.close()
                }
                if preflight {
                    guard kind == .result,
                          let result = try? JSONDecoder().decode(Wire.Result.self, from: Data(payload)) else {
                        fail("Malformed server information")
                        return
                    }
                    if let version = result.protocolVersion, version != Wire.version {
                        fail("Unsupported protocol version: \(version)"); return
                    }
                    if let format = result.layoutFormat, !["weighted-v1", "binary-v1"].contains(format) {
                        fail("Unsupported layout format: \(format)"); return
                    }
                    if let format = result.snapshotFormat, format != "ghostty-vt-v1" {
                        fail("Unsupported snapshot format: \(format)"); return
                    }
                    let ownership = result.supports("paneControl")
                    var observing = true
                    let accepted = lock.withLock {
                        guard !closed else { return false }
                        observing = observationChoice ?? (observer || (!ownership && legacyObserver))
                        var open = request
                        if ownership {
                            open.paneControl = true
                            open.observer = observing
                        }
                        if observing { open.cols = 0; open.rows = 0 }
                        ownershipSupported = ownership
                        inputAllowed = !ownership && !observing
                        opened = true
                        socket.send(Wire.frame(.open, json: open))
                        if ownership, observationChoice == false { socket.send(.paneControl, [1]) }
                        return true
                    }
                    guard accepted else { return }
                    preflight = false
                    post(.negotiated(ownership: ownership, observing: observing))
                    return
                }
                switch kind {
                case .attached:
                    guard let info = try? JSONDecoder().decode(Wire.PaneInfo.self, from: Data(payload)) else {
                        fail("Malformed pane attachment"); return
                    }
                    attached = true
                    post(.attached(info))
                case .snapshot:
                    guard !negotiate || (attached && !payload.isEmpty) else {
                        fail("Malformed pane snapshot"); return
                    }
                    snapshot = true
                    post(.snapshot(Array(payload)))
                case .output:
                    guard !negotiate || snapshot else { fail("Output before pane snapshot"); return }
                    post(.output(Array(payload)[...]))
                case .resized:
                    guard let size = Wire.decodeSize(payload), !negotiate || snapshot else {
                        fail("Malformed pane resize"); return
                    }
                    post(.resized(size))
                case .ownership:
                    guard payload.count == 1, let value = payload.first, value <= 1,
                          lock.withLock({ ownershipSupported }) else {
                        fail("Malformed pane ownership"); return
                    }
                    let owner = value == 1
                    lock.withLock { inputAllowed = owner }
                    post(.ownership(owner))
                case .failure:
                    guard let result = try? JSONDecoder().decode(Wire.Result.self, from: Data(payload)),
                          let error = result.error else { fail("Malformed pane failure"); return }
                    fail(error)
                case .exited:
                    guard payload.count == 4 else { fail("Malformed pane exit"); return }
                    let bits = payload.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    let code = Int32(bitPattern: bits)
                    if code < 0 { fail("Pane attachment failed") } else { post(.exited(code)) }
                default: break
                }
            }
            lock.withLock { inputAllowed = false; opened = false }
            post(.disconnected)
        }
    }

    /// Sends mutations only while this stream owns input.
    func send(input bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.withLock { if !closed && inputAllowed { socket.send(.input, bytes) } }
    }

    func send(resize size: GridSize) {
        lock.withLock { if !closed && inputAllowed { socket.send(.resize, Wire.encode(size)) } }
    }

    /// Ends the pane's shell with SIGHUP when this stream owns input.
    func kill() {
        lock.withLock { if !closed && inputAllowed { socket.send(.kill) } }
    }

    /// Requests modern ownership, or explicitly enables input on a legacy stream.
    func takeControl() {
        let legacy = lock.withLock {
            observationChoice = false
            guard !closed && opened else { return false }
            if ownershipSupported { socket.send(.paneControl, [1]); return false }
            inputAllowed = true
            return true
        }
        if legacy { post(.ownership(true)) }
    }

    /// Stops local input immediately and releases modern ownership if available.
    func releaseControl() {
        let released = lock.withLock {
            observationChoice = true
            guard !closed && opened else { return false }
            inputAllowed = false
            if ownershipSupported { socket.send(.paneControl, [0]) }
            return true
        }
        if released { post(.ownership(false)) }
    }

    /// Reports a failed attachment to the endpoint's transport owner.
    func reportFailure(at endpoint: Endpoint) {
        Remote.connectionFailed(endpoint, transport: socket)
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
        let bytes = event.byteCount
        lock.lock()
        // Pause the reader, letting socket/link flow control take over. A
        // single large event is allowed when the batch is otherwise empty.
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
        DispatchQueue.main.async { self.deliver() }
    }

    /// Drain at most 256 KiB / 64 events per main-queue turn. An event is
    /// indivisible and may occupy one larger delivery. Keep wire ordering and
    /// backpressure while scheduling the remaining output behind input work.
    @MainActor private func deliver() {
        lock.lock()
        var count = 0, bytes = 0
        for event in pending.prefix(64) {
            if count > 0, bytes + event.byteCount > 256 * 1024 { break }
            count += 1
            bytes += event.byteCount
        }
        let events = Array(pending.prefix(count))
        pending.removeFirst(count)
        pendingBytes -= bytes
        let more = !pending.isEmpty
        scheduled = more
        lock.broadcast()
        lock.unlock()
        if !events.isEmpty { onEvents?(events) }
        if more { DispatchQueue.main.async { self.deliver() } }
    }
}

/// The app's control connection: it watches the server's tree and sends it
/// commands. `onState` and command completions run on the main thread.
final class ControlConnection: @unchecked Sendable {
    private let socket: Transport
    var receivedBytes: UInt64 { socket.receivedBytes }
    /// The actual selected stream, rather than the server's advertised transports.
    var usesEncryptedLink: Bool { socket is LinkStream }
    private let lock = NSLock()
    /// Completions for commands sent and not yet answered; the server answers
    /// a connection's commands in order.
    private var waiting: [@MainActor (Wire.Result) -> Void] = []
    private var latestState: Wire.State?
    private var stateScheduled = false
    private var closed = false
    private var discardErrors = false
    @MainActor var onState: ((Wire.State) -> Void)?
    @MainActor var onDisconnect: (() -> Void)?
    @MainActor var onError: ((String) -> Void)?

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
                    guard let state = try? JSONDecoder().decode(Wire.State.self, from: Data(payload)) else {
                        postError("Malformed state"); return
                    }
                    postState(state)
                case .result:
                    let decoded = try? JSONDecoder().decode(Wire.Result.self, from: Data(payload))
                    if decoded == nil { postError("Malformed result") }
                    let result = decoded ?? Wire.Result(error: "malformed result")
                    let done = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
                    if let done { DispatchQueue.main.async { done(result) } }
                default: postError("Unexpected control frame")
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

    func close() {
        lock.withLock { discardErrors = true }
        finish(disconnected: false)
        socket.close()
    }

    /// Preserve a protocol error followed by EOF; explicit detach suppresses it.
    private func postError(_ message: String) {
        DispatchQueue.main.async { [self] in
            guard !lock.withLock({ discardErrors }) else { return }
            MainActor.assumeIsolated { onError?(message) }
        }
    }

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
