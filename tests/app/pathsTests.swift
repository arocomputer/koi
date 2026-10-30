import Foundation
import Testing
@testable import Koi

/// Runtime path checks join the hosted socket suite without changing process environment.
extension SocketTests {
    /// Long runtime paths use the same private socket directory as the server.
    @Test func longRuntimeDirectoryMatchesServerFallback() {
        let name = "server-\(Wire.version).sock"
        let prefix = "/tmp/"
        let atLimit = URL(fileURLWithPath: prefix + String(repeating: "x", count: 100 - prefix.utf8.count - name.utf8.count - 1))
        #expect(atLimit.appendingPathComponent(name).path.utf8.count == 100)
        #expect(Paths.runtimeDirectory(atLimit).path == "/tmp/koi-\(getuid())")
        let below = URL(fileURLWithPath: String(atLimit.path.dropLast()))
        #expect(Paths.runtimeDirectory(below) == below)
    }

    /// Unix socket limits count UTF-8 bytes rather than displayed characters.
    @Test func multibyteRuntimeDirectoryUsesByteLimit() {
        let candidate = URL(fileURLWithPath: "/tmp/" + String(repeating: "é", count: 45))
        let socket = candidate.appendingPathComponent("server-\(Wire.version).sock").path
        #expect(socket.count < 100 && socket.utf8.count >= 100)
        #expect(Paths.runtimeDirectory(candidate).path == "/tmp/koi-\(getuid())")
    }
}
