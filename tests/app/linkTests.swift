import Foundation
import Testing
@testable import Koi

/// Link checks join the serialized server suite because TestServer sets the
/// process-wide KOI_DIR. Separate suites could connect to each other's server.
extension SessionTests {
    /// The real path minus SSH: an offer from the server over the local
    /// socket, then control and commands over the link. The offer's secret is
    /// the only key that opens it.
    @Test func offerFromTheServerOpensALinkForItsSecretOnly() throws {
        let server = try TestServer()
        defer { server.stop() }
        let offer = try #require(server.offer())
        let wrong = String(offer.secret.dropFirst(2)) + "00"
        #expect(LinkClient(host: "127.0.0.1", port: offer.port, secret: Wire.secretBytes(wrong)) == nil)
        let link = try #require(LinkClient(host: "127.0.0.1", port: offer.port, secret: Wire.secretBytes(offer.secret)))
        let stream = try #require(link.open())
        let control = try #require(TestControl(socket: stream))
        let made = control.run(.init(op: .newTab))
        #expect(made.tab != nil)
        #expect(control.waitFor { $0.tabs.map(\.id) == [made.tab!] })
    }
}

extension SessionTests {
    /// A stream keeps its link alive: after the last outside reference to
    /// the LinkClient is gone, the stream still sends, reads and closes.
    @Test func streamKeepsItsLinkAlive() throws {
        let server = try TestServer()
        defer { server.stop() }
        let offer = try #require(server.offer())
        var link = LinkClient(host: "127.0.0.1", port: offer.port, secret: Wire.secretBytes(offer.secret))
        let stream = try #require(link?.open())
        link = nil
        let control = try #require(TestControl(socket: stream))
        let made = control.run(.init(op: .newTab))
        #expect(made.tab != nil)
        stream.close()
    }
}
