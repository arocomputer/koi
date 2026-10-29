import Foundation
import Testing
@testable import Koi

/// A slowly arriving snapshot keeps initialization alive; a stalled one expires.
@Test func partialSnapshotProgressExtendsInitializationDeadline() {
    var deadline = ConnectionDeadline(now: 0)
    let initial = deadline.stalled(receivedBytes: 0, now: 7)
    let partial = deadline.stalled(receivedBytes: 100, now: 7.5)
    let more = deadline.stalled(receivedBytes: 200, now: 14)
    let waiting = deadline.stalled(receivedBytes: 200, now: 21)
    let stalled = deadline.stalled(receivedBytes: 200, now: 22)
    #expect(!initial && !partial && !more && !waiting && stalled)
}

/// A busy main actor must apply backpressure rather than retaining unlimited
/// output; closing the connection must still wake its reader immediately.
@Suite @MainActor struct ClientTests {
    /// A full pending queue must yield to another main-queue operation before
    /// parsing the rest, rather than delivering all 8 MiB in one callback.
    @Test func outputBacklogYieldsBetweenBoundedDeliveries() async throws {
        let source = BurstTransport(metadata: false)
        let connection = PaneConnection(.init(pane: "test", cols: 80, rows: 24, cellWidth: 8, cellHeight: 16), socket: source)
        defer { connection.close() }
        var deliveries = 0
        var observed: Int?
        connection.onEvents = { events in
            deliveries += 1
            #expect(events.reduce(0) { $0 + $1.byteCount } <= 256 * 1024)
            if deliveries == 1 {
                DispatchQueue.main.async {
                    observed = deliveries
                    connection.close()
                }
            }
        }
        #expect(source.waitForBackpressure())
        for _ in 0..<100 where observed == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed == 1)
        #expect(source.waitUntilDone())
    }

    @Test(arguments: [false, true]) func aBusyMainActorBoundsOutputAndCloseWakesTheReader(metadata: Bool) async throws {
        let source = BurstTransport(metadata: metadata)
        let connection = PaneConnection(.init(pane: "test", cols: 80, rows: 24, cellWidth: 8, cellHeight: 16), socket: source)
        var delivered = 0
        connection.onEvents = { delivered += $0.count }
        exerciseBackpressure(source, connection: connection)
        try await Task.sleep(for: .milliseconds(30))
        #expect(delivered == 0, "explicit detach drops the pending batch")
    }

    /// Intentionally keep the main actor busy during this synchronous phase;
    /// then the async test yields so it can check cancelled delivery.
    private func exerciseBackpressure(_ source: BurstTransport, connection: PaneConnection) {
        #expect(source.waitForBackpressure())
        #expect(source.done.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(source.produced < 1000)
        connection.close()
        #expect(source.done.wait(timeout: .now() + 2) == .success)
    }
}

/// Produces more output than the UI queue can hold without a real server or
/// timing-dependent kernel buffers. All shared state is condition-protected.
private final class BurstTransport: Transport, @unchecked Sendable {
    private let condition = NSCondition()
    private var stopped = false
    private var count = 0
    private let metadata: Bool
    let done = DispatchSemaphore(value: 0)

    init(metadata: Bool) { self.metadata = metadata }

    var produced: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    func waitForBackpressure() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let previous = count
            if !condition.wait(until: min(deadline, Date().addingTimeInterval(0.05))), count == previous, count >= 16 {
                return true
            }
        }
        return false
    }

    /// Bounded join after closing the fixture, outside async semaphore APIs.
    func waitUntilDone() -> Bool { done.wait(timeout: .now() + 2) == .success }

    func send(_ bytes: [UInt8]) {}

    func readFrames(_ handle: (Wire.Kind, ArraySlice<UInt8>) -> Void) {
        defer { done.signal() }
        let output: [UInt8]
        if metadata {
            let info = Wire.PaneInfo(id: "test", pid: 1, title: String(repeating: "a", count: 64 * 1024),
                                    cwd: "/tmp", home: "/tmp", program: "test", shell: "zsh", fullscreen: false, status: .idle)
            output = Array(try! JSONEncoder().encode(info))
        } else {
            output = [UInt8](repeating: 65, count: 64 * 1024)
        }
        for _ in 0..<3000 {
            condition.lock()
            if stopped { condition.unlock(); return }
            count += 1
            condition.broadcast()
            condition.unlock()
            handle(metadata ? .attached : .output, output[...])
        }
    }

    func close() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A reconnect waits on events, not only a clock: the local server's socket
/// directory changing wakes every waiter at once. Serialized: fixtures move
/// the process-wide KOI_DIR, and the watch must be on the current one.
@MainActor extension SessionTests {
    @Test @MainActor func reconnectsWakeWhenTheServerDirectoryChanges() async throws {
        final class Count { var fired = 0 }
        let count = Count()
        Reconnect.rewatch()
        let token = Reconnect.observe { count.fired += 1 }
        defer { Reconnect.stopObserving(token) }
        // The network monitor reports its current path once on start; let that pass.
        try await Task.sleep(for: .milliseconds(150))
        let baseline = count.fired
        let probe = (Paths.socket as NSString).deletingLastPathComponent + "/probe-\(getpid())"
        #expect(FileManager.default.createFile(atPath: probe, contents: nil))
        defer { try? FileManager.default.removeItem(atPath: probe) }
        for _ in 0..<50 where count.fired == baseline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(count.fired > baseline)
    }
}

/// Exercises negotiation and ownership using an isolated in-memory stream.
@Suite @MainActor struct PaneNegotiationTests {
    private var request: Wire.OpenRequest {
        .init(pane: "test", cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for connection")
    }

    @Test func checksCompatibilityBeforeOpening() async throws {
        let stream = NegotiationTransport()
        let pane = PaneConnection(request, socket: stream, negotiate: true)
        defer { pane.close() }
        #expect(stream.frames.map(\.0) == [.command])
        stream.receive(.result, #"{"protocolVersion":7}"#)
        try await wait { stream.isClosed }
        #expect(stream.frames.map(\.0) == [.command])
    }

    @Test func rejectsUnknownSnapshotBeforeOpening() async throws {
        let stream = NegotiationTransport()
        let pane = PaneConnection(request, socket: stream, negotiate: true)
        defer { pane.close() }
        stream.receive(.result, #"{"protocolVersion":6,"snapshotFormat":"future"}"#)
        try await wait { stream.isClosed }
        #expect(stream.frames.map(\.0) == [.command])
    }

    @Test func legacyObserverStaysPassiveUntilClaimed() async throws {
        let stream = NegotiationTransport()
        let pane = PaneConnection(request, socket: stream, legacyObserver: true, negotiate: true)
        defer { pane.close() }
        stream.receive(.result, #"{"error":"unsupported"}"#)
        try await wait { stream.frames.count == 2 }
        let open = try JSONDecoder().decode(Wire.OpenRequest.self, from: Data(stream.frames[1].1))
        #expect(open.cols == 0 && open.rows == 0 && open.paneControl == nil)
        pane.send(input: [1]); pane.kill()
        #expect(stream.frames.count == 2 && !pane.allowsInput)
        pane.takeControl()
        pane.send(input: [2])
        #expect(pane.allowsInput && stream.frames.last?.0 == .input)
    }

    /// A choice made while server information is in flight governs the open,
    /// including an explicit claim that must supersede another modern owner.
    @Test(arguments: [false, true]) func controlChoiceDuringPreflightIsRetained(observing: Bool) async throws {
        for modern in [false, true] {
            let stream = NegotiationTransport()
            let pane = PaneConnection(request, socket: stream, observer: !observing, legacyObserver: true, negotiate: true)
            defer { pane.close() }
            if observing { pane.releaseControl() } else { pane.takeControl() }
            stream.receive(.result, modern ? #"{"protocolVersion":6,"capabilities":["paneControl"]}"# : #"{"error":"unsupported"}"#)
            try await wait { stream.frames.count >= 2 }
            let open = try JSONDecoder().decode(Wire.OpenRequest.self, from: Data(stream.frames[1].1))
            #expect((open.cols == 0 && open.rows == 0) == observing)
            if modern {
                #expect(open.observer == observing)
                #expect(stream.frames.contains { $0.0 == .paneControl } == !observing)
            } else { #expect(pane.allowsInput == !observing) }
        }
    }

    @Test func ownershipAcknowledgementAndRevocationGateInput() async throws {
        let stream = NegotiationTransport()
        let pane = PaneConnection(request, socket: stream, negotiate: true)
        defer { pane.close() }
        stream.receive(.result, #"{"protocolVersion":6,"capabilities":["paneControl"]}"#)
        try await wait { stream.frames.count == 2 }
        let open = try JSONDecoder().decode(Wire.OpenRequest.self, from: Data(stream.frames[1].1))
        #expect(open.paneControl == true && open.observer == false && pane.supportsOwnership)
        pane.send(input: [1])
        #expect(stream.frames.count == 2)
        stream.receive(.ownership, bytes: [1])
        try await wait { pane.allowsInput }
        pane.send(input: [2])
        stream.receive(.ownership, bytes: [0])
        try await wait { !pane.allowsInput }
        pane.send(input: [3]); pane.kill()
        #expect(stream.frames.filter { $0.0 == .input }.count == 1)
        #expect(!stream.frames.contains { $0.0 == .kill })
    }

    /// Choosing observation stays passive even on a local legacy server.
    @Test func explicitObservationZerosLegacyOpenAndBlocksInput() async throws {
        let stream = NegotiationTransport()
        let pane = PaneConnection(request, socket: stream, observer: true, negotiate: true)
        defer { pane.close() }
        stream.receive(.result, #"{"error":"unsupported command"}"#)
        try await wait { stream.frames.count == 2 }
        let open = try JSONDecoder().decode(Wire.OpenRequest.self, from: Data(stream.frames[1].1))
        #expect(open.cols == 0 && open.rows == 0 && !pane.allowsInput)
        pane.send(input: [3])
        pane.send(resize: GridSize(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16))
        #expect(stream.frames.count == 2)
    }

    @Test func failureAndMalformedExitAreNotExitEvents() async throws {
        for (kind, bytes) in [(Wire.Kind.failure, Array(#"{"error":"denied"}"#.utf8)), (.exited, [1])] {
            let stream = NegotiationTransport()
            let pane = PaneConnection(request, socket: stream)
            var failures = 0
            var exits = 0
            pane.onEvents = { events in
                for event in events {
                    if case .failure = event { failures += 1 }
                    if case .exited = event { exits += 1 }
                }
            }
            stream.receive(kind, bytes: bytes)
            try await wait { failures == 1 }
            #expect(exits == 0)
            pane.close()
        }
    }

    @Test func malformedControlStateReportsError() async throws {
        let stream = NegotiationTransport()
        let control = Control(socket: stream)
        defer { control.close() }
        var error: String?
        control.onError = { error = $0 }
        stream.receive(.state, "invalid")
        stream.endInput()
        try await wait { error != nil }
        #expect(error == "Malformed state")
    }
}

/// A blocking fake transport records sent frames and supplies deterministic replies.
private final class NegotiationTransport: Transport, @unchecked Sendable {
    private let condition = NSCondition()
    private var incoming: [(Wire.Kind, [UInt8])] = []
    private var sent: [(Wire.Kind, [UInt8])] = []
    private var stopped = false
    private var eof = false
    var frames: [(Wire.Kind, [UInt8])] { condition.withLock { sent } }
    var isClosed: Bool { condition.withLock { stopped } }

    func send(_ bytes: [UInt8]) {
        var reader = FrameReader()
        bytes.withUnsafeBytes { reader.append($0) }
        guard let frame = try? reader.next() else { return }
        condition.withLock { sent.append((frame.0, Array(frame.1))) }
    }
    func receive(_ kind: Wire.Kind, _ text: String) { receive(kind, bytes: Array(text.utf8)) }
    func receive(_ kind: Wire.Kind, bytes: [UInt8]) {
        condition.withLock { incoming.append((kind, bytes)); condition.signal() }
    }
    func readFrames(_ handle: (Wire.Kind, ArraySlice<UInt8>) -> Void) {
        while true {
            condition.lock()
            while incoming.isEmpty && !stopped && !eof { condition.wait() }
            guard !stopped, !incoming.isEmpty else { condition.unlock(); return }
            let frame = incoming.removeFirst()
            condition.unlock()
            handle(frame.0, frame.1[...])
        }
    }
    /// EOF follows buffered frames; cancellation through close discards them.
    func endInput() { condition.withLock { eof = true; condition.broadcast() } }
    func close() { condition.withLock { stopped = true; condition.broadcast() } }
}
