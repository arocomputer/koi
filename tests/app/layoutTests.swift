import Foundation
import Testing
@testable import Koi

extension SessionTests {
    /// Rapid changes from multiple workspaces share one in-memory layout and
    /// the final value survives an immediate app-termination flush.
    @Test @MainActor func layoutPersistenceMergesWorkspacesAndFlushesTheLatestSelection() throws {
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        var first = Layout.load()
        first.machines["local"] = .init(tab: "a")
        first.save()
        var second = Layout.load()
        second.machines["remote"] = .init(tab: "r")
        second.machines["local"] = .init(tab: "b")
        second.save()
        Layout.flush()
        let saved = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: Paths.layout))
        #expect(saved.machines["local"]?.tab == "b")
        #expect(saved.machines["remote"]?.tab == "r")
    }
}
