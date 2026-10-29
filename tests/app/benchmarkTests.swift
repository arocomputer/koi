import Foundation
import Testing
@testable import Koi

/// Throughput and latency of the engine, the renderer and a keystroke's
/// round trip. Throughput and frame/keystroke latency have regression bounds;
/// snapshot timings are informational and restored screen contents are checked.
/// They run in the serialized
/// suite so parallel fixtures neither skew them nor get starved by them.
@MainActor extension SessionTests {
    /// A keystroke's round trip through the whole stack but the display: the
    /// client socket or encrypted loopback link, the server, the PTY, the shell's echo, back through the
    /// server to a client engine. Uses a private server and a program that
    /// echoes each byte itself with the terminal's own echo off, so every
    /// sample crosses the PTY twice and a real process once, like a shell's
    /// line editor does, independent of the user's prompt.
    @Test(arguments: [false, true]) @MainActor func keystrokeEchoRoundTrip(remote: Bool) throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        var create = Wire.Command(op: .newTab)
        create.startup = "stty -echo -icanon; exec /bin/cat"
        let made = control.run(create)
        let id = try #require(made.pane)
        var transport: Transport?
        if remote {
            let offer = try #require(server.offer())
            let link = try #require(LinkClient(host: "127.0.0.1", port: offer.port, secret: Wire.secretBytes(offer.secret)))
            let stream: LinkStream = try #require(link.open(), "UDP benchmark must not fall back to a local socket")
            transport = stream
        }
        let pane = try #require(TestPane(id, transport: transport))
        defer { pane.close() }
        pane.type("ready")
        #expect(pane.waitForText("ready"))
        var samples: [Double] = []
        for i in 0..<40 {
            let glyph = String(UnicodeScalar(UInt8(97 + i % 26)))
            let before = pane.visibleText().count(where: { String($0) == glyph })
            let start = DispatchTime.now().uptimeNanoseconds
            pane.type(glyph)
            while pane.visibleText().count(where: { String($0) == glyph }) == before,
                  DispatchTime.now().uptimeNanoseconds - start < 10_000_000_000 { usleep(100) }
            try #require(pane.visibleText().count(where: { String($0) == glyph }) > before,
                         "keystroke echo timed out after 10 seconds at sample \(i)")
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print(String(format: "keystroke echo round trip (\(remote ? "UDP loopback" : "local socket")): median %.2f ms, p90 %.2f ms, min %.2f ms (n=%d)",
                     median, samples[Int(Double(samples.count) * 0.9)], samples[0], samples.count))
        #expect(median < 5, "a keystroke's round trip through server and shell runs in tenths of a millisecond")
    }

    @Test @MainActor func engineWriteAndFrameAssembly() throws {
        let terminal = VTTerminal(cols: 200, rows: 60)
        var bytes: [UInt8] = []
        for i in 0..<2_000_000 { bytes += Array("\(i)\r\n".utf8) }
        let megabytes = Double(bytes.count) / 1_048_576
        var start = Date()
        bytes.withUnsafeBytes { terminal.write($0) }
        let writeSeconds = Date().timeIntervalSince(start)
        print(String(format: "engine write: %.1f MB in %.0f ms = %.0f MB/s", megabytes, writeSeconds * 1000, megabytes / writeSeconds))
        #expect(megabytes / writeSeconds > 20, "the engine parses well over a hundred megabytes a second")

        let metrics = FontMetrics(size: 13, scale: 2)
        let renderer = try #require(Renderer(metrics: metrics))
        start = Date()
        var frames = 0
        for _ in 0..<60 {
            terminal.write(Array("line \(frames)\r\n".utf8))
            _ = renderer.prepareFrame(terminal, force: true)
            frames += 1
        }
        let frameMs = Date().timeIntervalSince(start) * 1000 / Double(frames)
        print(String(format: "full 200x60 frame assembly: %.2f ms per frame", frameMs))
        #expect(frameMs < 15, "a full frame assembles in a couple of milliseconds")
        start = Date()
        for _ in 0..<60 {
            terminal.write(Array("x".utf8))
            _ = renderer.prepareFrame(terminal)
        }
        let incrementalMs = Date().timeIntervalSince(start) * 1000 / 60
        print(String(format: "one-cell incremental frame: %.3f ms per frame", incrementalMs))
        #expect(incrementalMs < 2, "an incremental frame costs a tenth of a millisecond")

        start = Date()
        let snapshot = terminal.snapshot()
        let snapshotMs = Date().timeIntervalSince(start) * 1000
        start = Date()
        let restored = try #require(VTTerminal(snapshot: snapshot), "snapshot must decode")
        print(String(format: "snapshot: %.1f MB encoded in %.0f ms, decoded in %.0f ms", Double(snapshot.count) / 1_048_576, snapshotMs, Date().timeIntervalSince(start) * 1000))
        #expect(restored.text() == terminal.text(), "snapshot preserves visible screen text")
    }
}
