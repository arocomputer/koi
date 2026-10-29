import AppKit
import Foundation
import Testing
@testable import Koi

/// Serializes fixtures sharing process-wide config, application events or KOI_DIR.
/// Servers and windows remain private; no test drives the user’s desktop.
@Suite(.serialized) struct SessionTests {
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
