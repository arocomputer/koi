import Foundation
import Testing
@testable import Koi

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
