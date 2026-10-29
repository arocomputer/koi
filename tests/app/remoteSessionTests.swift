import Darwin
import Foundation
import Testing
@testable import Koi

/// These checks change KOI_DIR and therefore share SessionTests' serialization.
extension SessionTests {
    /// Real shell responses must remain ordered despite UDP loss and reordering.
    @Test func impairedUDPDeliversOrderedProcessEcho() throws {
        try exerciseImpairedProcess(changePath: false)
    }

    /// NAT rebinding preserves a live encrypted stream; a fresh encrypted
    /// connection then reattaches to the same still-running process.
    @Test func encryptedSessionSurvivesRebindAndReconnect() throws {
        try exerciseImpairedProcess(changePath: true)
    }

    /// Uses a private PTY with kernel echo disabled. Sequence numbers come from
    /// shell state, so echoed input or a replacement process cannot pass.
    private func exerciseImpairedProcess(changePath: Bool) throws {
        let previousDirectory = ProcessInfo.processInfo.environment["KOI_DIR"]
        defer {
            if let previousDirectory { setenv("KOI_DIR", previousDirectory, 1) }
            else { unsetenv("KOI_DIR") }
        }
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        var create = Wire.Command(op: .newTab)
        create.startup = "stty -echo; n=0; printf 'process-ready\\n'; while IFS= read -r line; do n=$((n+1)); printf 'reply-%s:%s\\n' \"$n\" \"$line\"; done"
        let id = try #require(control.run(create).pane)
        let offer = try #require(server.offer())
        let relay = try NetworkFixture(serverPort: offer.port)
        defer { relay.stop() }
        let link = try #require(LinkClient(host: "127.0.0.1", port: relay.port,
                                          secret: Wire.secretBytes(offer.secret)))
        let stream = try #require(link.open())
        defer { stream.close() }
        let pane = try #require(TestPane(id, cols: 100, rows: 40, transport: stream))
        defer { pane.close() }
        try #require(pane.waitForText("process-ready"))

        for index in 1...12 { pane.type("item-\(index)\n") }
        try #require(pane.waitForText("reply-12:item-12"), "process echo has a ten-second deadline")
        let expected = (1...12).map { "reply-\($0):item-\($0)" }.joined(separator: "\n")
        let lines = pane.visibleText().components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("reply-") }
        #expect(lines.joined(separator: "\n") == expected, "no missing, duplicated or reordered process replies")

        if changePath {
            let ports = try relay.rebind()
            #expect(ports.0 != ports.1)
            pane.type("after-rebind\n")
            try #require(pane.waitForText("reply-13:after-rebind"), "same encrypted stream must survive source-port migration")
            #expect(!link.isClosed)
            pane.close()

            // A new offer gives the reconnect fresh cryptographic state; the
            // original pane and shell must keep their identity and counter.
            let nextOffer = try #require(server.offer())
            let nextRelay = try NetworkFixture(serverPort: nextOffer.port)
            defer { nextRelay.stop() }
            let nextLink = try #require(LinkClient(host: "127.0.0.1", port: nextRelay.port,
                                                  secret: Wire.secretBytes(nextOffer.secret)))
            let nextStream = try #require(nextLink.open())
            defer { nextStream.close() }
            let reattached = try #require(TestPane(id, cols: 100, rows: 40, transport: nextStream))
            defer { reattached.close() }
            try #require(reattached.waitForText("reply-13:after-rebind"), "reattach restores prior output")
            reattached.type("after-reconnect\n")
            try #require(reattached.waitForText("reply-14:after-reconnect"), "the original shell is still running")
        }
        #expect(relay.counts.dropped > 0, "the path must actually discard datagrams")
        #expect(relay.counts.forwarded > 0)
    }
}
