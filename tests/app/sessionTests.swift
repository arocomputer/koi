import AppKit
import Foundation
import Testing
@testable import Koi

/// Serializes fixtures sharing process-wide config, application events or KOI_DIR.
/// Servers and windows remain private; no test drives the user’s desktop.
@Suite(.serialized) struct SessionTests {
    /// An unvisited tab has no cached view, but its close command still needs
    /// server-side ownership; a second window cannot end the owner's shell.
    @Test @MainActor func anUnvisitedLocalTabCannotBeClosedByAnotherWindow() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab))
        let tab = try #require(made.tab), pane = try #require(made.pane)
        let owner = Workspace(.local), observer = Workspace(.local)
        owner.start(); observer.start()
        defer { owner.detachAll(); observer.detachAll() }
        try await waitForTabOrder([tab], in: owner)
        try await waitForTabOrder([tab], in: observer)
        let view = owner.view(for: pane)
        for _ in 0..<200 where !view.canControl { try await Task.sleep(for: .milliseconds(10)) }
        try #require(view.canControl)
        #expect(observer.attachedViews.isEmpty)
        var rejection: String?
        observer.onError = { rejection = $0 }
        observer.closeTab(tab)
        for _ in 0..<200 where rejection == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rejection == "NOTOWNER")
        #expect(control.waitFor { $0.tabs.first?.panes.first?.id == pane })
        #expect(owner.state.tabs.map(\.id) == [tab] && view.canControl)
    }

    /// A fresh watch and its ordered reply reconcile a coalesced competing name
    /// without exposing the pre-command name while the reply is in flight.
    @Test @MainActor func renameWaitsForAFencedAuthoritativeTree() async throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let stream = RenameTransport()
        let control = Control(socket: stream)
        let workspace = Workspace(.local, control: control, controlTransport: stream)
        defer { workspace.detachAll() }
        control.onState = { workspace.apply($0) }
        func state(_ tabName: String, _ groupName: String) -> Wire.State {
            guard case .tab(var tab) = fixture.state(["a"]).items[0] else { fatalError("fixture") }
            tab.name = tabName
            return Wire.State(items: [.group(.init(id: "g", name: groupName, tabs: [tab]))])
        }
        func receive(_ value: Wire.State) throws {
            stream.receive(.state, try JSONEncoder().encode(value))
        }
        workspace.apply(state("old", "old group"))
        workspace.renameTab("a", to: "mine")
        try receive(state("old", "old group"))
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where stream.frames.filter({ $0 == .watch }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingTabNames["a"] == "mine")
        try receive(state("theirs", "old group"))
        stream.receive(.result, Data("{\"error\":\"unsupported\"}".utf8))
        for _ in 0..<200 where workspace.pendingTabNames["a"] != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingTabNames["a"] == nil)
        #expect(workspace.tab("a")?.tab.name == "theirs")

        // A tree delivered before the command callback must also be fenced.
        workspace.renameGroup("g", to: "mine group")
        try receive(state("theirs", "their group"))
        for _ in 0..<200 where workspace.tab("a")?.group?.name != "their group" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingGroupNames["g"] == "mine group")
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where stream.frames.filter({ $0 == .watch }).count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingGroupNames["g"] == "mine group")
        try receive(state("theirs", "their group"))
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where workspace.pendingGroupNames["g"] != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingGroupNames["g"] == nil)
        #expect(workspace.tab("a")?.group?.name == "their group")
    }

    /// A late reply for an older submission cannot retire the newer name.
    @Test @MainActor func renameReplyKeepsTheNewerRequest() async throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let stream = RenameTransport()
        let control = Control(socket: stream)
        let workspace = Workspace(.local, control: control, controlTransport: stream)
        defer { workspace.detachAll() }
        control.onState = { workspace.apply($0) }
        workspace.apply(fixture.state(["a"]))
        workspace.renameTab("a", to: "first")
        workspace.renameTab("a", to: "second")
        stream.receive(.result, Data("{\"error\":\"rejected\"}".utf8))
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where stream.frames.filter({ $0 == .watch }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingTabNames["a"] == "second")
        var state = fixture.state(["a"])
        if case .tab(var tab) = state.items[0] { tab.name = "other"; state.items[0] = .tab(tab) }
        stream.receive(.state, try JSONEncoder().encode(state))
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where workspace.pendingTabNames["a"] != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingTabNames["a"] == nil)
        #expect(workspace.tab("a")?.tab.name == "other")

        workspace.renameTab("a", to: "third")
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where stream.frames.filter({ $0 == .watch }).count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        workspace.renameTab("a", to: "fourth")
        if case .tab(var tab) = state.items[0] { tab.name = "third"; state.items[0] = .tab(tab) }
        stream.receive(.state, try JSONEncoder().encode(state))
        stream.receive(.result, Data("{}".utf8))
        try await Task.sleep(for: .milliseconds(20))
        #expect(workspace.pendingTabNames["a"] == "fourth", "an older refresh cannot retire a later submission")
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where stream.frames.filter({ $0 == .watch }).count < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        if case .tab(var tab) = state.items[0] { tab.name = "latest"; state.items[0] = .tab(tab) }
        stream.receive(.state, try JSONEncoder().encode(state))
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where workspace.pendingTabNames["a"] != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.tab("a")?.tab.name == "latest")
        #expect(workspace.pendingTabNames["a"] == nil)
    }

    /// Reconnection's first full tree retires an acknowledged rename whose
    /// original connection ended before its refresh barrier was answered.
    @Test @MainActor func reconnectTreeRetiresAnAcknowledgedRename() async throws {
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        let serverControl = try #require(TestControl())
        let id = try #require(serverControl.run(.init(op: .newTab)).tab)
        _ = serverControl.run(.init(op: .renameTab, tab: id, name: "server"))
        let stream = RenameTransport()
        let control = Control(socket: stream)
        let workspace = Workspace(.local, control: control, controlTransport: stream)
        defer { workspace.detachAll() }
        workspace.apply(Wire.State(items: [.tab(.init(id: id, panes: [], layout: .pane("fixture")))]))
        workspace.renameTab(id, to: "mine")
        stream.receive(.result, Data("{}".utf8))
        for _ in 0..<200 where stream.frames.filter({ $0 == .watch }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.pendingTabNames[id] == "mine")
        control.close()
        workspace.start()
        for _ in 0..<300 where workspace.pendingTabNames[id] != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.pendingTabNames[id] == nil)
        #expect(workspace.tab(id)?.tab.name == "server")
    }

    /// Another app window must observe a shared PTY until it explicitly claims
    /// control; reconnecting it must preserve the first client's running shell.
    @Test @MainActor func secondClientCannotReshapeOrEndTheOwnersPane() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let pane = try #require(control.run(.init(op: .newTab)).pane)
        _ = NSApplication.shared
        let firstWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 500),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 90, height: 60),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        defer {
            firstWindow.contentView = nil; secondWindow.contentView = nil
            firstWindow.close(); secondWindow.close()
        }
        let first = TerminalView(pane: pane, at: .local)
        firstWindow.contentView = first
        defer { first.detach() }
        first.attach()
        for _ in 0..<300 where !first.canControl { try await Task.sleep(for: .milliseconds(10)) }
        try #require(first.canControl)
        let workspace = Workspace(.local)
        workspace.start()
        defer { workspace.detachAll() }
        for _ in 0..<300 where workspace.selectedPane == nil { try await Task.sleep(for: .milliseconds(10)) }
        let observingView = try #require(workspace.selectedView)
        for _ in 0..<300 where !observingView.connectionDescription.hasPrefix("Observing") { try await Task.sleep(for: .milliseconds(10)) }
        try #require(observingView.observing)
        var rejections: [String] = []
        workspace.onError = { rejections.append($0) }
        workspace.closePane()
        workspace.closeTab()
        do {
            _ = try await workspace.perform(.init(op: .resetPane, pane: pane))
            Issue.record("An observing client reset the shared terminal")
        } catch {}
        #expect(rejections.count == 3 && rejections.allSatisfy { $0.contains("Take Control") })
        let original = first.currentGridSize
        let second = TerminalView(pane: pane, at: .local)
        secondWindow.contentView = second
        defer { second.detach() }
        second.attach()
        for _ in 0..<300 where !second.connectionDescription.hasPrefix("Observing") { try await Task.sleep(for: .milliseconds(10)) }
        try #require(second.observing && second.terminal != nil)
        // A zero-grid watcher sees server resizes without becoming an owner.
        let monitor = try #require(TestPane(pane, cols: 0, rows: 0))
        defer { monitor.close() }
        first.setFrameSize(NSSize(width: 850, height: 520))
        let resized = first.currentGridSize
        #expect(resized != original)
        #expect(monitor.waitForResize(cols: resized.cols, rows: resized.rows))
        second.takeControl()
        for _ in 0..<300 where !second.canControl || !first.observing { try await Task.sleep(for: .milliseconds(10)) }
        try #require(second.canControl && first.observing)
        let small = second.currentGridSize
        #expect(monitor.waitForResize(cols: small.cols, rows: small.rows))
        second.reconnect()
        for _ in 0..<300 where !second.canControl { try await Task.sleep(for: .milliseconds(10)) }
        #expect(second.canControl)
        second.observe()
        first.takeControl()
        for _ in 0..<300 where !first.canControl { try await Task.sleep(for: .milliseconds(10)) }
        #expect(first.canControl && second.observing)
        second.detach()
        monitor.type("printf 'owner-still-running\\n'\r")
        #expect(monitor.waitForText("owner-still-running"))
    }

    /// The point of the server: what a pane printed is still there, with its
    /// shell running, after the client goes away and a new one attaches.
    @Test(arguments: [false, true]) func paneOutlivesItsClient(remote: Bool) throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab))
        let paneID = try #require(made.pane)

        /// Use a real socket or UDP stream, retaining functional echo coverage
        /// without the benchmark's sampling loop or machine-speed threshold.
        func attach() throws -> TestPane {
            var transport: Transport?
            if remote {
                let offer = try #require(server.offer())
                let link = try #require(LinkClient(host: "127.0.0.1", port: offer.port, secret: Wire.secretBytes(offer.secret)))
                transport = try #require(link.open())
            }
            return try #require(TestPane(paneID, transport: transport))
        }

        let first = try attach()
        first.type("echo koi-$((40+2))\r")
        #expect(first.waitForText("koi-42"))
        first.close()

        let second = try attach()
        defer { second.close() }
        #expect(second.waitForText("koi-42"), "the snapshot has the earlier output")
        second.type("echo again-$((1+1))\r")
        #expect(second.waitForText("again-2"), "the shell still runs")
    }

    /// The tree operations the app relies on, round-tripped through the real
    /// binary on one server: splits lie flat and collapse again, swaps trade
    /// places, groups form where the target was and vanish when emptied,
    /// names are trimmed, and an absurd grid is refused without harm. The
    /// server's own tests cover each operation's edge cases in-process.
    @Test func treeCommandsRoundTripThroughTheRealServer() throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let first = control.run(.init(op: .newTab))
        let a = try #require(first.tab), pane = try #require(first.pane)
        let b = try #require(control.run(.init(op: .newTab, tab: a)).tab)
        let c = try #require(control.run(.init(op: .newTab, tab: b)).tab)
        #expect(control.waitFor { $0.tabs.map(\.id) == [a, b, c] })

        let right = try #require(control.run(.init(op: .splitPane, pane: pane, direction: .right)).pane)
        let third = try #require(control.run(.init(op: .splitPane, pane: right, direction: .right)).pane)
        #expect(control.waitFor { state in
            guard let t = state.tabs.first, case .split(let s) = t.layout else { return false }
            return s.direction == .right && s.children.map(\.layout) == [.pane(pane), .pane(right), .pane(third)] && t.panes.count == 3
        }, "three right-splits make one flat row of three")
        _ = control.run(.init(op: .swapPanes, pane: pane, target: third))
        #expect(control.waitFor { state in
            guard let t = state.tabs.first, case .split(let s) = t.layout else { return false }
            return s.children.map(\.layout) == [.pane(third), .pane(right), .pane(pane)]
        }, "the two panes traded places")
        _ = control.run(.init(op: .closePane, pane: right))
        _ = control.run(.init(op: .closePane, pane: third))
        #expect(control.waitFor { $0.tabs.first?.layout == .pane(pane) && $0.tabs.first?.panes.count == 1 },
                "a split with one child left gives way to that child")

        let refused = control.run(.init(op: .splitPane, pane: pane, cols: 65535, rows: 65535))
        #expect(refused.error != nil && refused.pane == nil)
        #expect(control.run(.init(op: .newTab, cols: 65535, rows: 65535)).error != nil)
        #expect(control.waitFor { $0.tabs.count == 3 && $0.tabs.first?.panes.count == 1 })

        _ = control.run(.init(op: .renameTab, tab: a, name: "  build  "))
        #expect(control.waitFor { $0.tabs.first?.name == "build" }, "trimmed and stored")
        _ = control.run(.init(op: .renameTab, tab: a, name: ""))
        #expect(control.waitFor { ($0.tabs.first?.name ?? "") == "" }, "cleared")

        let group = try #require(control.run(.init(op: .group, tab: c, target: a)).group)
        #expect(control.waitFor { state in
            guard state.items.count == 2, case .group(let g) = state.items[0] else { return false }
            return g.id == group && g.tabs.map(\.id) == [a, c] && state.items[1].id == b
        })
        _ = control.run(.init(op: .move, tab: a))
        _ = control.run(.init(op: .move, tab: c))
        #expect(control.waitFor { $0.items.map(\.id) == [b, a, c] }, "the emptied group is gone")

        _ = control.run(.init(op: .closeTab, tab: a))
        #expect(control.waitFor { $0.tabs.map(\.id) == [b, c] })
    }

    /// Horizontal drops must insert on either side without an off-by-one
    /// after removing the source, and must keep the selected tab selected.
    @Test @MainActor func reorderingTabsBothWaysPreservesSelection() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let a = try #require(control.run(.init(op: .newTab)).tab)
        let b = try #require(control.run(.init(op: .newTab, tab: a)).tab)
        let c = try #require(control.run(.init(op: .newTab, tab: b)).tab)
        let workspace = Workspace(.local)
        workspace.start()
        defer { workspace.detachAll() }
        try await waitForTabOrder([a, b, c], in: workspace)
        workspace.select(b)

        workspace.reorder(a, to: c, after: true)
        try await waitForTabOrder([b, c, a], in: workspace)
        #expect(workspace.selectedTab == b)
        workspace.reorder(a, to: b, after: false)
        try await waitForTabOrder([a, b, c], in: workspace)
        #expect(workspace.selectedTab == b)
    }

    /// The horizontal list flattens groups, but the server counts a whole
    /// group as one top-level slot; drops into a group use its child slots.
    @Test @MainActor func reorderingTabsCountsGroupsAndUsesTheTargetGroup() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let a = try #require(control.run(.init(op: .newTab)).tab)
        let b = try #require(control.run(.init(op: .newTab, tab: a)).tab)
        let c = try #require(control.run(.init(op: .newTab, tab: b)).tab)
        let d = try #require(control.run(.init(op: .newTab, tab: c)).tab)
        let group = try #require(control.run(.init(op: .group, tab: b, target: a)).group)
        let workspace = Workspace(.local)
        workspace.start()
        defer { workspace.detachAll() }
        try await waitForTabOrder([a, b, c, d], in: workspace)

        workspace.reorder(d, to: c, after: false)
        try await waitForTabOrder([a, b, d, c], in: workspace)
        #expect(workspace.tab(a)?.group?.id == group)
        workspace.reorder(c, to: a, after: true)
        try await waitForTabOrder([a, c, b, d], in: workspace)
        #expect(workspace.tab(c)?.group?.id == group)
    }

    /// Yield to the real control connection's main-actor state delivery.
    @MainActor private func waitForTabOrder(_ expected: [String], in workspace: Workspace) async throws {
        for _ in 0..<300 {
            if workspace.state.tabs.map(\.id) == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(workspace.state.tabs.map(\.id) == expected)
    }

    /// A pre-weighted remote server's split state must reach the workspace,
    /// rather than leave its existing single-pane presentation frozen.
    @Test @MainActor func legacyRemoteSplitUpdatesTheVisibleWorkspace() async throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let peer = Socket(fd: fds[1])
        let control = Control(socket: Socket(fd: fds[0]))
        defer { control.close(); peer.close() }
        let workspace = fixture.workspace
        workspace.apply(fixture.state(["a"]))
        var shown: [String] = []
        workspace.onShow = { shown = $0?.layout.panes ?? [] }
        control.onState = { workspace.apply($0) }
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.state(["a"], splitFirst: true))) as? [String: Any])
        var items = try #require(object["items"] as? [[String: Any]])
        var tab = try #require((items[0]["tab"] as? [String: Any])?["_0"] as? [String: Any])
        tab["layout"] = ["split": ["id": "a-split", "direction": "right", "ratio": 0.4,
                                  "first": ["pane": "a-pane"], "second": ["pane": "a-second"]]]
        items[0] = ["tab": ["_0": tab]]
        object["items"] = items
        peer.send(Wire.frame(.state, Array(try JSONSerialization.data(withJSONObject: object))))
        for _ in 0..<200 {
            if shown == ["a-pane", "a-second"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(shown == ["a-pane", "a-second"])
        #expect(workspace.focusedPane == "a-pane")
    }

    /// A remote machine's connection is `Koi --stdio` over SSH; without SSH,
    /// the relay must carry the protocol both ways just the same.
    @Test func stdioRelayCarriesTheProtocol() throws {
        let server = try TestServer()
        defer { server.stop() }
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let relay = Process()
        relay.executableURL = server.process.executableURL
        relay.arguments = ["--stdio"]
        relay.environment = ProcessInfo.processInfo.environment
        let theirs = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        relay.standardInput = theirs
        relay.standardOutput = theirs
        try relay.run()
        try theirs.close()
        defer { relay.terminate() }

        let control = try #require(TestControl(socket: Socket(fd: fds[0])))
        let made = control.run(.init(op: .newTab))
        #expect(made.tab != nil)
        #expect(control.waitFor { $0.tabs.map(\.id) == [made.tab!] })
    }

    /// A pane's shell sees the size its view asks for, and the view hears
    /// back once the pane has resized. The app opens a pane before its view
    /// has a size, so the first size is tiny; the real one must still take.
    @Test func aPaneResizesToWhatItsViewAsksForEvenFromATinyStart() throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab))
        let pane = try #require(TestPane(made.pane!, cols: 2, rows: 1))
        pane.resize(GridSize(cols: 120, rows: 40, cellWidth: 8, cellHeight: 16))
        #expect(pane.waitForResize(cols: 120, rows: 40))
        pane.type("stty size\r")
        #expect(pane.waitForText("40 120"))
    }

    /// A zero-size attach (`koi capture`, `koi send`) reads the pane without
    /// reshaping it, so a CLI command never shrinks the interactive client.
    @Test func attachingWithoutASizeKeepsThePaneSize() throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab))
        let client = try #require(TestPane(made.pane!, cols: 100, rows: 30))
        #expect(client.waitForResize(cols: 100, rows: 30))

        let watcher = try #require(TestPane(made.pane!, cols: 0, rows: 0))
        defer { watcher.close() }
        client.type("stty size\r")
        #expect(client.waitForText("30 100"), "the watcher left the size alone")
    }

    /// A large process snapshot must not hide the program name. Use our
    /// own binary as a passive relay so the snapshot includes its environment.
    @Test @MainActor func treeShowsProgramWithLargeArgumentSnapshot() throws {
        let server = try TestServer(extraEnvironment: ["KOI_TEST_LARGE_ENV": String(repeating: "x", count: 16_384)])
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab))
        let pane = try #require(TestPane(made.pane!))
        let path = try #require(server.process.executableURL).path
        pane.type(TerminalView.shellQuoted(path) + " --stdio" + String(UnicodeScalar(13)))
        #expect(control.waitFor { $0.tabs.first?.panes.first?.program == "koi" })
    }

    /// Watchers see what runs in a pane, read from the kernel, and see it go
    /// when the shell is back at its prompt.
    @Test func treeShowsTheForegroundProgram() throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let made = control.run(.init(op: .newTab, cwd: "/tmp"))
        let pane = try #require(TestPane(made.pane!))

        pane.type("sleep 30\r")
        #expect(control.waitFor { $0.tabs.first?.panes.first?.program == "sleep" })
        pane.type("\u{03}")
        #expect(control.waitFor { $0.tabs.first?.panes.first?.program == "" })
        #expect(control.state.tabs.first?.panes.first?.cwd.hasSuffix("/tmp") == true)
    }
}

/// In-memory control stream for deterministic command and watcher ordering.
private final class RenameTransport: Transport, @unchecked Sendable {
    private let condition = NSCondition()
    private var incoming: [(Wire.Kind, [UInt8])] = []
    private var sent: [Wire.Kind] = []
    private var stopped = false
    var frames: [Wire.Kind] { condition.withLock { sent } }

    func send(_ bytes: [UInt8]) {
        var reader = FrameReader()
        bytes.withUnsafeBytes { reader.append($0) }
        guard let frame = try? reader.next() else { return }
        condition.withLock { sent.append(frame.0) }
    }
    func receive(_ kind: Wire.Kind, _ data: Data) {
        condition.withLock { incoming.append((kind, Array(data))); condition.signal() }
    }
    func readFrames(_ handle: (Wire.Kind, ArraySlice<UInt8>) -> Void) {
        while true {
            condition.lock()
            while incoming.isEmpty && !stopped { condition.wait() }
            guard !stopped else { condition.unlock(); return }
            let frame = incoming.removeFirst()
            condition.unlock()
            handle(frame.0, frame.1[...])
        }
    }
    func close() { condition.withLock { stopped = true; condition.broadcast() } }
}

extension SessionTests {
    /// An explicit resize hold never delays attachment or output. The shell
    /// keeps its creation size until that independent owner releases the hold.
    @Test @MainActor func aNewPaneAttachesDuringItsResizeHoldAtTheCreationSize() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let control = try #require(TestControl())
        let pane = try #require(control.run(.init(op: .newTab, cols: 100, rows: 30)).pane)
        let terminal = TerminalView(pane: pane, at: .local)
        terminal.beginResizeHold()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        defer { terminal.detach(); window.close() }
        terminal.attach()
        for _ in 0..<200 {
            if terminal.terminal != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.terminal?.size.cols == 100)
        #expect(terminal.terminal?.size.rows == 30)
        #expect(terminal.holdsResizes)
        let final = terminal.currentGridSize
        terminal.endResizeHold()
        for _ in 0..<200 {
            if terminal.terminal?.size.cols == final.cols && terminal.terminal?.size.rows == final.rows { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.terminal?.size.cols == final.cols)
        #expect(terminal.terminal?.size.rows == final.rows)
    }

}

extension SessionTests {
    /// Group searches retain reading order and exact tab/pane destinations.
    @Test @MainActor func paletteWorkKeepsGroupContextAndNavigationTargets() throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let tabs = fixture.state(["a", "b", "c", "d"], splitFirst: true).tabs
        fixture.workspace.apply(.init(items: [
            .tab(tabs[2]),
            .group(.init(id: "finance", name: "Finance", tabs: [tabs[0], tabs[1]])),
            .group(.init(id: "unnamed", name: "", tabs: [tabs[3]])),
        ]))
        var destinations: [String] = []
        let items = PaletteSearch.workItems(in: fixture.workspace) { tab, pane in
            destinations.append("\(tab):\(pane ?? "tab")")
        }
        for item in items {
            if case .perform(let navigate) = item.operation { navigate() }
        }
        #expect(destinations == ["c:c-pane", "a:tab", "a:a-pane", "a:a-second", "b:b-pane", "d:d-pane"])
        let grouped = PaletteSearch.results(items, query: "finance", recent: [])
        #expect(grouped.map(\.id) == Array(items[1...4]).map(\.id))
    }

    /// Short commands never replace chrome, while commands and status consumers
    /// see their authoritative metadata during the presentation delay.
    @Test @MainActor func briefCommandsKeepTabAndHeaderPresentationStable() async throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.apply(fixture.state(["a"]))
        var pane = try #require(workspace.selectedPane)
        let prompt = pane
        var shown: [Wire.PaneInfo] = []
        workspace.onShow = { tab in
            if let tab { shown.append(contentsOf: tab.panes) }
        }
        pane.program = "git"
        pane.title = "git status"
        pane.cwd = "/tmp/command"
        fixture.report(pane)
        #expect(workspace.selectedPane == pane)
        #expect(shown.isEmpty, "transient metadata alone must not refresh headers")
        pane.status = .working
        pane.fullscreen = true
        fixture.report(pane)
        #expect(workspace.selectedPane == pane)
        let display = workspace.presentedPane(pane)
        #expect(display.program.isEmpty && display.title == prompt.title && display.cwd == prompt.cwd)
        #expect(display.status == .working && display.fullscreen)
        #expect(shown.last == display, "headers receive live status with the same chrome as tabs")
        try await Task.sleep(for: .milliseconds(30))
        fixture.report(prompt)
        try await Task.sleep(for: .milliseconds(350))
        #expect(workspace.presentedPane(prompt) == prompt)
        #expect(shown.allSatisfy { $0.program.isEmpty && $0.title == prompt.title })
        #expect(TabLabel.tab(display, Programs.style(for: display)).title == "zsh")
        #expect(TabLabel.make(display, Programs.style(for: display)).title
            == TabLabel.make(prompt, Programs.style(for: prompt)).title)
    }

    /// A sustained program commits its latest title even if it keeps reporting
    /// titles faster than the debounce interval; later title updates are immediate.
    @Test @MainActor func sustainedProgramPresentationSurvivesTitleChurn() async throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.apply(fixture.state(["a"]))
        var pane = try #require(workspace.selectedPane)
        var shown: Wire.PaneInfo?
        workspace.onShow = { shown = $0?.panes.first }
        pane.program = "vim"
        var committed = false
        for index in 0..<20 {
            pane.title = "Document \(index)"
            fixture.report(pane)
            try await Task.sleep(for: .milliseconds(30))
            if workspace.presentedPane(pane).program == "vim" { committed = true; break }
        }
        #expect(committed, "title changes must not keep restarting program presentation")
        let display = workspace.presentedPane(pane)
        #expect(display.title == pane.title)
        #expect(shown == display, "the timer commits headers without another server update")
        #expect(TabLabel.tab(display, Programs.style(for: display)).title == pane.title)
        #expect(TabLabel.make(display, Programs.style(for: display)).title == pane.title)
        let previousTitle = pane.title
        pane.title = "Temporary title"
        fixture.report(pane)
        #expect(workspace.presentedPane(pane).title == "Temporary title")
        pane.title = previousTitle
        fixture.report(pane)
        #expect(workspace.presentedPane(pane).title == previousTitle)
        pane.title = "Final title"
        fixture.report(pane)
        #expect(workspace.presentedPane(pane).title == "Final title")
        #expect(shown?.title == "Final title")
    }

    /// Hidden panes settle independently, and tab/focus/zoom changes never flush
    /// a transient command or wait for its display timer.
    @Test @MainActor func presentationDebouncePreservesImmediateSelectionAndTopology() async throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.apply(fixture.state(["a", "b"], splitFirst: true))
        workspace.select("a")
        var first = try #require(workspace.selectedPane)
        var second = try #require(workspace.tab("b")?.tab.panes.first)
        first.program = "git"
        fixture.report(first)
        second.program = "vim"
        fixture.report(second)
        var tree = workspace.state
        var tab = try #require(tree.tabs.first)
        tab.name = "Review"
        tree.items[0] = .tab(tab)
        tree.items.append(contentsOf: fixture.state(["c"]).items)
        workspace.apply(tree)
        #expect(workspace.presentedTab(tab).name == "Review")
        let added = try #require(workspace.tab("c")?.tab.panes.first)
        #expect(workspace.presentedPane(added) == added, "new panes do not wait for existing timers")
        workspace.toggleZoom()
        workspace.focus("a-second")
        #expect(workspace.focusedPane == "a-second" && workspace.zoomedPane == nil)
        workspace.select("b")
        #expect(workspace.selectedPane == second)
        #expect(workspace.presentedPane(second).program.isEmpty)
        workspace.select("a")
        for _ in 0..<100 {
            if workspace.presentedPane(second).program == "vim" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.presentedPane(first).program == "git")
        #expect(workspace.presentedPane(second).program == "vim", "hidden tabs settle too")
        workspace.apply(fixture.state(["b"]))
        #expect(workspace.selectedTab == "b" && workspace.state.tabs.count == 1)
    }

    /// Replaced candidates, removed IDs and detached workspaces cannot publish
    /// a stale program later, including when the same pane ID is reused.
    @Test @MainActor func presentationDebounceCancelsReplacedAndRemovedPanes() async throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        let initial = fixture.state(["a", "b"])
        workspace.apply(initial)
        var pane = try #require(workspace.selectedPane)
        pane.program = "git"
        fixture.report(pane)
        try await Task.sleep(for: .milliseconds(150))
        pane.program = "vim"
        fixture.report(pane)
        try await Task.sleep(for: .milliseconds(150))
        #expect(workspace.presentedPane(pane).program.isEmpty, "a replacement gets its own settling interval")
        workspace.apply(fixture.state(["b"]))
        workspace.apply(initial)
        try await Task.sleep(for: .milliseconds(350))
        let restored = try #require(workspace.tab("a")?.tab.panes.first)
        #expect(workspace.presentedPane(restored).program.isEmpty)
        pane.program = "git"
        fixture.report(pane)
        workspace.detachAll()
        var callbacks = 0
        workspace.onShow = { _ in callbacks += 1 }
        try await Task.sleep(for: .milliseconds(350))
        #expect(callbacks == 0)
    }

    /// All focus entry points reveal the destination before the coordinator can
    /// install keyboard focus; it must never present a focused, hidden terminal.
    @Test @MainActor func movingFocusOutsideZoomPresentsOneVisibleDestination() throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.apply(fixture.state(["a", "b"], splitFirst: true))
        workspace.select("a")
        workspace.toggleZoom()
        var presentations: [(String?, String?)] = []
        workspace.onShow = { _ in presentations.append((workspace.focusedPane, workspace.zoomedPane)) }
        workspace.focusPane(offset: 1)
        #expect(workspace.focusedPane == "a-second" && workspace.zoomedPane == nil)
        #expect(presentations.count == 1)
        #expect(presentations.first?.0 == "a-second" && presentations.first?.1 == nil)
        workspace.toggleZoom()
        presentations.removeAll()
        workspace.focus("a-pane")
        #expect(presentations.count == 1)
        #expect(presentations.first?.0 == "a-pane" && presentations.first?.1 == nil)
        workspace.focus("not-in-this-tab")
        #expect(presentations.count == 1)
    }

    /// Failed close attempts retain selection. Actual removal chooses a neighbor
    /// using the old order, presenting only the final topology and selection.
    @Test @MainActor func tabRemovalAndNeighborSelectionArePresentedTogether() throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.apply(fixture.state(["a", "b", "c"]))
        workspace.select("a")
        var presentations: [[String]] = []
        workspace.onShow = { _ in
            presentations.append([workspace.selectedTab ?? ""] + workspace.state.tabs.map(\.id))
        }
        workspace.closeTab()
        #expect(workspace.selectedTab == "a" && presentations.isEmpty)
        workspace.apply(fixture.state(["b", "c"]))
        #expect(presentations == [["b", "b", "c"]])
        workspace.apply(fixture.state(["a", "b", "c"]))
        workspace.select("c")
        presentations.removeAll()
        workspace.apply(fixture.state(["a", "b"]))
        #expect(presentations == [["b", "a", "b"]])
    }

    /// Every command family shares offline reporting, including drag completion;
    /// rejected commands cannot clear zoom, change focus or start rename/select.
    @Test @MainActor func offlineCommandsReportErrorsAndCompleteDragWithoutChangingSelection() throws {
        let fixture = try WorkspaceStateFixture()
        defer { fixture.close() }
        let workspace = fixture.workspace
        workspace.apply(fixture.state(["a", "b"], splitFirst: true))
        workspace.select("a")
        workspace.toggleZoom()
        var errors: [String] = []
        workspace.onError = { errors.append($0) }
        var dragResults: [Bool] = []
        let commands: [() -> Void] = [
            { workspace.newTab() },
            { workspace.splitPane(.right) },
            { workspace.closePane() },
            { workspace.swapPanes("a-pane", onto: "a-second") },
            { workspace.resizeSplit("a-split", index: 0, ratio: 0.6) },
            { workspace.closeTab() },
            { workspace.closeGroup("group") },
            { workspace.ungroup("group") },
            { workspace.renameGroup("group", to: "Work") },
            { workspace.renameTab("a", to: "Work") },
            { workspace.closeOtherTabs("a") },
            { workspace.drop("a", onto: "b") },
            { workspace.drop("a", intoGroup: "group") },
            { workspace.reorder("a", to: "b", after: true) },
            { workspace.commitTabDrag("a", placement: .end) { dragResults.append($0) } },
            { workspace.dropAtEnd("a") },
        ]
        for command in commands {
            let previous = errors.count
            command()
            #expect(errors.count == previous + 1)
            #expect(errors.last?.localizedCaseInsensitiveContains("offline") == true)
        }
        #expect(dragResults == [false])
        #expect(workspace.selectedTab == "a" && workspace.focusedPane == "a-pane")
        #expect(workspace.zoomedPane == "a-pane" && workspace.renamingGroup == nil)
        #expect(workspace.attachedViews.isEmpty, "offline commands must not create terminal connections for sizing")
    }

    /// Real Control failures retain FIFO reporting and do not swallow the next
    /// successful command's callback or its pending selection of a new tab.
    @Test @MainActor func rejectedCommandsReportBeforeSuccessfulNewTabSelection() async throws {
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        let control = try #require(TestControl())
        let a = try #require(control.run(.init(op: .newTab)).tab)
        let invalid: [Wire.Command] = [
            .init(op: .renameGroup, group: "missing", name: "Work"),
            .init(op: .resizeSplit, split: "missing", ratio: 0.6, index: 0),
            .init(op: .swapPanes, pane: "missing", target: "also-missing"),
        ]
        let expected = try invalid.map { try #require(control.run($0).error) }
        let workspace = Workspace(.local)
        workspace.start()
        defer { workspace.detachAll() }
        try await waitForTabOrder([a], in: workspace)
        var errors: [String] = []
        workspace.onError = { errors.append($0) }
        workspace.renameGroup("missing", to: "Work")
        workspace.resizeSplit("missing", index: 0, ratio: 0.6)
        workspace.swapPanes("missing", onto: "also-missing")
        workspace.newTab()
        for _ in 0..<300 {
            if errors.count == expected.count, workspace.state.tabs.count == 2, workspace.selectedTab != a { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(errors == expected)
        #expect(workspace.state.tabs.count == 2)
        #expect(workspace.selectedTab == workspace.state.tabs.last?.id)
    }
}

/// Authoritative workspace snapshots in private storage, without starting or
/// connecting to a server. Explicit teardown drains persistence before removal.
@MainActor private final class WorkspaceStateFixture {
    let workspace = Workspace(.local)
    private let directory: URL
    private let previousDirectory = ProcessInfo.processInfo.environment["KOI_DIR"]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("koi-workspace-\(UUID())")
        try Paths.ensurePrivateDirectory(directory)
        setenv("KOI_DIR", directory.path, 1)
    }

    /// Build reading-order fixtures with an optional split in the first tab.
    func state(_ tabs: [String], splitFirst: Bool = false) -> Wire.State {
        Wire.State(items: tabs.enumerated().map { index, id in
            let ids = splitFirst && index == 0 ? [id + "-pane", id + "-second"] : [id + "-pane"]
            let panes = ids.map { pane in
                Wire.PaneInfo(id: pane, pid: 1, title: "", cwd: "/tmp", home: "/tmp", program: "", shell: "zsh", fullscreen: false, status: .idle)
            }
            let layout: Wire.LayoutNode = ids.count == 1 ? .pane(ids[0]) : .split(.init(id: id + "-split", direction: .right,
                children: ids.map { .init(layout: .pane($0), weight: 1) }))
            return .tab(.init(id: id, panes: panes, layout: layout))
        })
    }

    /// Apply one pane's server metadata without changing the fixture topology.
    func report(_ pane: Wire.PaneInfo) {
        var state = workspace.state
        state.items = state.items.map { item in
            guard case .tab(var tab) = item else { return item }
            tab.panes = tab.panes.map { $0.id == pane.id ? pane : $0 }
            return .tab(tab)
        }
        workspace.apply(state)
    }

    /// Restore the process environment only after all fixture work has ended.
    func close() {
        workspace.onShow = nil
        workspace.onError = nil
        workspace.detachAll()
        Layout.flush()
        if let previousDirectory { setenv("KOI_DIR", previousDirectory, 1) } else { unsetenv("KOI_DIR") }
        try? FileManager.default.removeItem(at: directory)
    }
}
