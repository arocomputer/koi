import Darwin
import Foundation
import Testing
@testable import Koi

/// Private-server project checks share SessionTests' process-wide KOI_DIR lock.
extension SessionTests {
    /// Restore through the app's real command/watcher path without hosting views.
    @Test @MainActor func projectRestorerPreservesJobsAndRestoresShellRecipesOnPrivateServer() async throws {
        let previousDirectory = ProcessInfo.processInfo.environment["KOI_DIR"]
        let previousConfig = Config.current
        defer {
            Config.current = previousConfig
            if let previousDirectory { setenv("KOI_DIR", previousDirectory, 1) }
            else { unsetenv("KOI_DIR") }
        }
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        let control = try #require(TestControl())
        let directory = server.dir.resolvingSymlinksInPath()
        let explicitMarker = directory.appendingPathComponent("explicit-startup")
        let unwantedMarker = directory.appendingPathComponent("global-startup")
        Config.current.startupCommand = "touch \(TerminalView.shellQuoted(unwantedMarker.path)); exec /bin/cat"

        for name in ["Existing build", "Existing review"] {
            let made = control.run(.init(op: .newTab, cwd: directory.path, startup: "exec /bin/cat"))
            let id = try #require(made.tab)
            try #require(made.error == nil)
            try #require(control.run(.init(op: .renameTab, tab: id, name: name)).error == nil)
        }
        try #require(control.waitFor { $0.tabs.count == 2 && $0.tabs.allSatisfy { $0.panes.first?.program == "cat" } })
        let existing = control.state

        /// Give each leaf a distinct directory, resolving aliases as the kernel does.
        func pane(_ id: String) throws -> Wire.PaneInfo {
            let cwd = directory.appendingPathComponent("work \(id)")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let physical = try #require(realpath(cwd.path, nil))
            defer { free(physical) }
            return .init(id: id, pid: 424242, title: "Saved process", cwd: String(cString: physical), home: "/unused",
                         program: "saved-program", shell: "zsh", fullscreen: false, status: .working)
        }
        let leaves = try ["a", "b", "c", "d", "e", "f"].map { try pane($0) }
        let layout = Wire.LayoutNode.split(.init(id: "root", direction: .right, children: [
            .init(layout: .split(.init(id: "same-direction", direction: .right, children: [
                .init(layout: .pane("a"), weight: 4), .init(layout: .pane("b"), weight: 1),
            ])), weight: 2),
            .init(layout: .split(.init(id: "perpendicular", direction: .down, children: [
                .init(layout: .pane("c"), weight: 1), .init(layout: .pane("d"), weight: 5),
            ])), weight: 3),
            .init(layout: .pane("e"), weight: 7),
        ]))
        let saved = Wire.State(items: [
            .tab(.init(id: "main", name: "Project splits", panes: Array(leaves.prefix(5)), layout: layout)),
            .group(.init(id: "solo", name: "Project solo", tabs: [
                .init(id: "helper-case", name: "Project shell", panes: [leaves[5]], layout: .pane("f")),
            ])),
        ])
        let startup = "printf '%s\\n' \"$PWD:$KOI_PANE\" > \(TerminalView.shellQuoted(explicitMarker.path)); exec /bin/cat"
        let project = try Project(snapshot: saved, name: "Private integration", endpoint: .local, startup: ["d": startup])
        let workspace = Workspace(.local)
        workspace.start()
        defer { workspace.detachAll() }
        for _ in 0..<500 {
            if workspace.state.tabs.map(\.id) == existing.tabs.map(\.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(workspace.state.tabs.map(\.id) == existing.tabs.map(\.id))
        var commands: [Wire.Command] = []
        let restorer = ProjectRestorer(command: { command in
            commands.append(command)
            return try await workspace.perform(command)
        }, state: { workspace.state }, select: { workspace.select($0) })
        let ids = try await restorer.restore(project)
        try #require(ids.count == 2)
        let restored = workspace.state
        #expect(restored.tabs.map(\.id) == existing.tabs.map(\.id) + ids)
        #expect(Array(restored.items.prefix(existing.items.count)) == existing.items)
        #expect(workspace.selectedTab == ids[0])
        let fresh = Array(restored.tabs.suffix(2))
        #expect(fresh.map(\.name) == saved.tabs.map(\.name))
        guard case .group(let group) = restored.items.last else {
            Issue.record("Expected restored singleton group"); return
        }
        #expect(group.name == "Project solo" && group.tabs.map(\.id) == [ids[1]])
        #expect(group.id != "solo")

        /// Compare ordered topology and exact relative vectors, ignoring fresh IDs.
        func expectLayout(_ recipe: Wire.LayoutNode, _ actual: Wire.LayoutNode) {
            switch (recipe, actual) {
            case (.pane(let old), .pane(let new)):
                #expect(old != new)
            case (.split(let old), .split(let new)):
                #expect(old.id != new.id)
                #expect(old.direction == new.direction)
                #expect(old.children.count == new.children.count)
                let total = old.children.reduce(0) { $0 + $1.weight }
                let actualTotal = new.children.reduce(0) { $0 + $1.weight }
                for (expected, child) in zip(old.children, new.children) {
                    #expect(abs(expected.weight / total - child.weight / actualTotal) < 1e-12)
                    expectLayout(expected.layout, child.layout)
                }
            default: Issue.record("Restored project topology differs from its recipe")
            }
        }
        var paneIDs: [String: String] = [:]
        for (recipe, tab) in zip(saved.tabs, fresh) {
            expectLayout(recipe.layout, tab.layout)
            #expect(tab.panes.count == recipe.panes.count)
            for (old, new) in zip(recipe.layout.panes, tab.layout.panes) { paneIDs[old] = new }
        }
        let oldPaneIDs = Set(existing.tabs.flatMap(\.panes).map(\.id) + leaves.map(\.id))
        #expect(Set(paneIDs.values).isDisjoint(with: oldPaneIDs))
        #expect(Set(ids).isDisjoint(with: Set(existing.tabs.map(\.id) + saved.tabs.map(\.id))))
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: explicitMarker.path), leaves.allSatisfy({ leaf in
                workspace.state.tabs.flatMap(\.panes).first { $0.id == paneIDs[leaf.id] }?.cwd == leaf.cwd
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for leaf in leaves {
            let live = try #require(workspace.state.tabs.flatMap(\.panes).first { $0.id == paneIDs[leaf.id] })
            #expect(live.cwd == leaf.cwd)
        }
        let explicitPane = try #require(paneIDs["d"])
        #expect(try String(contentsOf: explicitMarker, encoding: .utf8) == leaves[3].cwd + ":" + explicitPane + "\n")
        let creations = commands.filter { $0.op == .newTab || $0.op == .splitPane }
        #expect(creations.filter { $0.startup != nil }.count == 1)
        #expect(creations.first { $0.startup != nil }?.startup == startup)
        #expect(creations.first { $0.startup != nil }?.cwd == leaves[3].cwd)
        #expect(!FileManager.default.fileExists(atPath: unwantedMarker.path))
        let plainID = try #require(paneIDs["a"])
        let plain = try #require(TestPane(plainID))
        defer { plain.close() }
        plain.type("printf '%s-%s\\n' plain shell\r")
        #expect(plain.waitForText("plain-shell"), "A pane without recipe startup remains an interactive shell")
        #expect(workspace.attachedViews.isEmpty)
    }
}
