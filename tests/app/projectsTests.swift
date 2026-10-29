import Foundation
import Testing
@testable import Koi

/// Project recipes protect directories and layout, without recording live work.
@Suite @MainActor struct ProjectTests {
    @Test func snapshotWhitelistsLayoutAndExplicitStartup() throws {
        let snapshot = projectState()
        let project = try Project(snapshot: snapshot, name: "  Review  ", endpoint: .ssh("dev@buildbox"))
        #expect(project.name == "Review")
        #expect(project.endpoint == .ssh("dev@buildbox"))
        #expect(project.tabs[0].layout.panes.map(\.cwd) == ["/work/a", "/work/b", "/work/c", "/work/d"])
        #expect(project.tabs.flatMap { $0.layout.panes }.allSatisfy { $0.startup == nil })
        let data = try JSONEncoder().encode(project)
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["PRIVATE_TITLE", "PRIVATE_PROGRAM", "PRIVATE_SHELL", "PRIVATE_HOME", "424242", "fullscreen", "status", "pid", "argv", "secret"] {
            #expect(!json.contains(forbidden), "Unexpected saved process metadata: \(forbidden)")
        }
        #expect(try JSONDecoder().decode(Project.self, from: data) == project)
        let explicit = try Project(snapshot: snapshot, name: "Review", endpoint: .local,
                                   startup: ["a": "printf '%s' 'user-authored command'"])
        #expect(explicit.tabs[0].layout.panes[0].startup == "printf '%s' 'user-authored command'")
        #expect(explicit.tabs[0].layout.panes.dropFirst().allSatisfy { $0.startup == nil })
    }

    @Test func malformedSnapshotsFailBeforePersistence() throws {
        var snapshot = projectState()
        if case .tab(var tab) = snapshot.items[0] {
            tab.panes.removeFirst()
            snapshot.items[0] = .tab(tab)
        }
        #expect(throws: (any Error).self) { try Project(snapshot: snapshot, name: "Bad", endpoint: .local) }
        snapshot = projectState()
        if case .tab(var tab) = snapshot.items[0], case .split(var split) = tab.layout {
            split.children[0].weight = 0
            tab.layout = .split(split)
            snapshot.items[0] = .tab(tab)
        }
        #expect(throws: (any Error).self) { try Project(snapshot: snapshot, name: "Bad", endpoint: .local) }
        #expect(throws: (any Error).self) { try Project(snapshot: .init(), name: "Empty", endpoint: .local) }
    }

    @Test func persistenceMergesOtherEntriesAndRenamesAndDeletesByID() throws {
        let directory = try projectDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/projects.json")
        let first = try ProjectStore(url: url)
        let stale = try ProjectStore(url: url)
        let a = try first.save(snapshot: projectState(), name: "A", endpoint: .local)
        let b = try stale.save(snapshot: projectState(), name: "B", endpoint: .ssh("buildbox"))
        try first.rename(a.id, to: "  Renamed  ")
        #expect(first.projects.map(\.name) == ["Renamed", "B"])
        var updated = a
        updated.name = "Updated"
        try stale.save(updated)
        #expect(stale.projects.map(\.id) == [a.id, b.id])
        try first.remove(b.id)
        #expect(try ProjectStore(url: url).projects == first.projects)
        #expect(first.projects.map(\.name) == ["Updated"])
        #expect(throws: (any Error).self) { try first.remove(b.id) }
        #expect(throws: (any Error).self) { try first.rename(a.id, to: " \n ") }
    }

    @Test func failedWriteDoesNotPublishAndCorruptFileIsNeverOverwritten() throws {
        let directory = try projectDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("projects.json")
        let store = try ProjectStore(url: url)
        let project = try store.save(snapshot: projectState(), name: "Keep", endpoint: .local)
        let data = try Data(contentsOf: url)
        // Prevent atomic replacement while keeping all I/O in the temporary directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: (any Error).self) { try store.rename(project.id, to: "Lost") }
        #expect(store.projects == [project])
        #expect(try Data(contentsOf: url) == data)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let corrupt = Data("broken catalog".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) { try ProjectStore(url: url) }
        #expect(throws: (any Error).self) { try store.remove(project.id) }
        #expect(try Data(contentsOf: url) == corrupt)
        #expect(store.projects == [project])
    }

    @Test func restoresFreshShellsGroupsTopologyAndExactWeightsWithoutTouchingExistingJobs() async throws {
        let saved = projectState()
        let project = try Project(snapshot: saved, name: "Review", endpoint: .local)
        let server = ProjectServer()
        let original = server.current
        let restorer = server.restorer()
        let ids = try await restorer.restore(project)
        #expect(ids.count == project.tabs.count)
        #expect(server.selected == ids[0])
        #expect(server.current.items.first == original.items.first)
        #expect(Set(ids).isDisjoint(with: Set(saved.tabs.map(\.id))))
        let restored = Wire.State(items: Array(server.current.items.dropFirst()))
        #expect(restored.items.count == saved.items.count)
        #expect(restored.tabs.map(\.name) == saved.tabs.map(\.name))
        #expect(projectShape(restored) == projectShape(saved))
        let captures = try Project(snapshot: restored, name: "Again", endpoint: .local)
        #expect(captures.tabs.flatMap { $0.layout.panes.map(\.cwd) } == project.tabs.flatMap { $0.layout.panes.map(\.cwd) })
        let resize = server.commands.filter { $0.op == .resizeSplit }
        #expect(resize.count == 3)
        #expect(resize.allSatisfy { $0.weights != nil && $0.ratio == nil })
        #expect(resize.map { $0.weights! } == [[2, 3, 7], [4, 1], [1, 5]])
        #expect(server.commands.filter { $0.op == .newTab || $0.op == .splitPane }.allSatisfy { $0.startup == nil })
        #expect(!server.commands.contains { $0.tab == "existing" || $0.pane == "existing-pane" || $0.target == "existing" })
        #expect(server.commands.filter { $0.op == .closeTab }.count == 1) // Singleton-group helper only.
    }

    @Test func sameDirectionNestedSplitsUseOnlyAPrivateHelperPane() async throws {
        var snapshot = projectState()
        guard case .tab(var tab) = snapshot.items[0], case .split(var root) = tab.layout,
              case .split(var nested) = root.children[0].layout else { Issue.record("Invalid fixture"); return }
        nested.direction = root.direction
        root.children[0].layout = .split(nested)
        tab.layout = .split(root)
        snapshot.items = [.tab(tab)]
        let server = ProjectServer()
        let ids = try await server.restorer().restore(Project(snapshot: snapshot, name: "Nested", endpoint: .local))
        let restored = Wire.State(items: [.tab(try #require(server.current.tabs.first { $0.id == ids[0] }))])
        #expect(projectShape(restored) == projectShape(snapshot))
        let closes = server.commands.filter { $0.op == .closePane }
        #expect(closes.count == 1)
        #expect(closes[0].pane != "existing-pane")
        #expect(restored.tabs[0].panes.count == tab.panes.count)
    }

    @Test func waitsForWatcherDeliveryAfterCommandResults() async throws {
        let server = ProjectServer()
        server.delayReads = 2
        let project = try Project(snapshot: simpleProjectState(), name: "Delayed", endpoint: .local)
        let ids = try await server.restorer().restore(project)
        #expect(server.selected == ids[0])
        #expect(server.delayedReads > 0)
    }

    @Test func failureStopsWithoutRollbackAndReportsCreatedTabs() async throws {
        let server = ProjectServer()
        server.failOn = .splitPane
        let original = server.current.items[0]
        do {
            try await server.restorer().restore(Project(snapshot: projectState(), name: "Broken", endpoint: .local))
            Issue.record("Expected split failure")
        } catch let failure as ProjectRestorer.Failure {
            #expect(failure.reason == "fixture shell launch failed")
            #expect(failure.operation.contains("split shell"))
            #expect(failure.createdTabs.count == 1)
            #expect(server.current.tabs.map(\.id).contains(failure.createdTabs[0]))
            #expect(failure.localizedDescription.contains("left for inspection"))
        }
        #expect(server.current.items[0] == original)
        #expect(server.commands.map(\.op) == [.newTab, .splitPane])
        #expect(server.selected == nil)
    }

    @Test func missingWatcherStateTimesOutBeforeAnyFurtherCommands() async throws {
        let server = ProjectServer()
        server.delayReads = 100
        do {
            try await server.restorer(timeout: .zero).restore(Project(snapshot: simpleProjectState(), name: "Timeout", endpoint: .local))
            Issue.record("Expected watcher timeout")
        } catch let failure as ProjectRestorer.Failure {
            #expect(failure.reason.contains("Timed out"))
            #expect(failure.operation.contains("new tab"))
            #expect(failure.createdTabs.count == 1)
        }
        #expect(server.commands.map(\.op) == [.newTab])
        #expect(server.selected == nil)
    }

    @Test func ignoredWeightVectorsFailInsteadOfClaimingSuccessfulRestoration() async throws {
        let server = ProjectServer()
        server.ignoreWeights = true
        do {
            try await server.restorer(timeout: .zero).restore(Project(snapshot: projectState(), name: "Old server", endpoint: .local))
            Issue.record("Expected unsupported weights failure")
        } catch let failure as ProjectRestorer.Failure {
            #expect(failure.operation.contains("exact weights"))
            #expect(failure.createdTabs.count == 1)
        }
        #expect(server.commands.last?.op == .resizeSplit)
        #expect(server.commands.filter { $0.op == .resizeSplit }.count == 1)
        #expect(server.selected == nil)
    }

    @Test func overlappingRestoreIsRejectedBeforeIssuingAnotherCommand() async throws {
        let project = try Project(snapshot: simpleProjectState(), name: "Busy", endpoint: .local)
        var release: CheckedContinuation<Void, Never>?
        var commands = 0
        let restorer = ProjectRestorer(command: { _ in
            commands += 1
            await withCheckedContinuation { release = $0 }
            return .init(error: "fixture stopped")
        }, state: { .init() }, select: { _ in Issue.record("Unexpected selection") })
        let first = Task { try await restorer.restore(project) }
        while release == nil { await Task.yield() }
        do {
            try await restorer.restore(project)
            Issue.record("Expected busy failure")
        } catch {
            #expect(error.localizedDescription.contains("already opening"))
        }
        #expect(commands == 1)
        release?.resume()
        do { _ = try await first.value; Issue.record("Expected fixture failure") }
        catch let failure as ProjectRestorer.Failure { #expect(failure.reason == "fixture stopped") }
    }
}

/// Fixture metadata is intentionally unsuitable for persistence.
private func projectPane(_ id: String, cwd: String? = nil) -> Wire.PaneInfo {
    .init(id: id, pid: 424242, title: "PRIVATE_TITLE", cwd: cwd ?? "/work/\(id)", home: "PRIVATE_HOME",
          program: "PRIVATE_PROGRAM", shell: "PRIVATE_SHELL", fullscreen: true, status: .working)
}

/// The smallest recipe that still exercises tab-name restoration.
private func simpleProjectState() -> Wire.State {
    .init(items: [.tab(.init(id: "simple", name: "Shell", panes: [projectPane("one")], layout: .pane("one")))])
}

/// Includes n-ary and alternating splits, a singleton group and a three-tab group.
private func projectState() -> Wire.State {
    func tab(_ id: String) -> Wire.TabInfo {
        .init(id: "tab-\(id)", name: "Tab \(id)", panes: [projectPane(id)], layout: .pane(id))
    }
    let nested = Wire.LayoutNode.split(.init(id: "nested", direction: .down, children: [
        .init(layout: .pane("a"), weight: 4), .init(layout: .pane("b"), weight: 1),
    ]))
    let layout = Wire.LayoutNode.split(.init(id: "root", direction: .right, children: [
        .init(layout: nested, weight: 2), .init(layout: .pane("c"), weight: 3), .init(layout: .pane("d"), weight: 7),
    ]))
    var pair = tab("pair")
    pair.panes = [projectPane("e"), projectPane("f")]
    pair.layout = .split(.init(id: "pair-split", direction: .down, children: [
        .init(layout: .pane("e"), weight: 1), .init(layout: .pane("f"), weight: 5),
    ]))
    return .init(items: [
        .tab(.init(id: "main", name: "Review", panes: ["a", "b", "c", "d"].map { projectPane($0) }, layout: layout)),
        .group(.init(id: "single-group", name: "Solo", tabs: [tab("solo")])),
        .group(.init(id: "group", name: "Work", tabs: [pair, tab("second"), tab("third")])),
        .tab(tab("last")),
    ])
}

/// Compares user-visible structure and relative weights independent of new IDs.
private func projectShape(_ state: Wire.State) -> [String] {
    func node(_ value: Wire.LayoutNode) -> String {
        switch value {
        case .pane: return "shell"
        case .split(let split):
            let total = split.children.reduce(0) { $0 + $1.weight }
            return "\(split.direction):" + split.children.map { "\($0.weight / total)[\(node($0.layout))]" }.joined(separator: ",")
        }
    }
    return state.items.flatMap { item -> [String] in
        switch item {
        case .tab(let tab): return ["tab:\(tab.name ?? ""):\(node(tab.layout))"]
        case .group(let group): return ["group:\(group.name)"] + group.tabs.map { "tab:\($0.name ?? ""):\(node($0.layout))" }
        }
    }
}

/// Allocate a private persistence directory without changing KOI_DIR or Paths.
private func projectDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("koi-projects-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A deterministic in-memory command adapter with native insertion/collapse
/// semantics. No PTYs, transports, processes, app state or production files.
@MainActor private final class ProjectServer {
    var current = Wire.State(items: [.tab(.init(id: "existing", name: "Running job",
        panes: [projectPane("existing-pane")], layout: .pane("existing-pane")))])
    var commands: [Wire.Command] = []
    var selected: String?
    var failOn: Wire.Command.Op?
    var ignoreWeights = false
    var delayReads = 0
    private(set) var delayedReads = 0
    private var published: Wire.State?
    private var pendingReads = 0
    private var serial = 0

    /// Use the production deadline; unrelated main-actor fixtures can delay
    /// delivery. Timeout-specific tests supply zero explicitly.
    func restorer(timeout: Duration = .seconds(3)) -> ProjectRestorer {
        .init(command: { try self.send($0) }, state: { self.read() }, select: { self.selected = $0 }, stateTimeout: timeout)
    }

    /// Delay publication by a fixed number of reads, without scheduling races.
    private func read() -> Wire.State {
        if pendingReads > 0 {
            pendingReads -= 1
            delayedReads += 1
            return published ?? current
        }
        published = current
        return current
    }

    /// Fresh IDs are deterministic and disjoint from fixture IDs.
    private func id() -> String {
        serial += 1
        return "fresh-\(serial)"
    }

    /// Apply only the native operations used by project restoration.
    private func send(_ command: Wire.Command) throws -> Wire.Result {
        commands.append(command)
        if command.op == failOn { return .init(error: "fixture shell launch failed") }
        published = current
        pendingReads = delayReads
        switch command.op {
        case .newTab:
            let tab = id(), pane = id()
            current.items.append(.tab(.init(id: tab, name: nil, panes: [projectPane(pane, cwd: command.cwd)], layout: .pane(pane))))
            return .init(tab: tab, pane: pane)
        case .splitPane:
            let pane = id(), split = id(), target = command.pane!, direction = command.direction!
            let tab = try #require(current.tabs.first { $0.pane(target) != nil }?.id)
            editTab(tab) { value in
                value.panes.append(projectPane(pane, cwd: command.cwd))
                func insert(_ node: inout Wire.LayoutNode) -> Bool {
                    switch node {
                    case .pane(let old) where old == target:
                        node = .split(.init(id: split, direction: direction, children: [
                            .init(layout: .pane(old), weight: 1), .init(layout: .pane(pane), weight: 1),
                        ]))
                        return true
                    case .split(var children):
                        if children.direction == direction,
                           let i = children.children.firstIndex(where: { $0.layout == .pane(target) }) {
                            children.children.insert(.init(layout: .pane(pane), weight: children.children[i].weight), at: i + 1)
                            node = .split(children)
                            return true
                        }
                        for i in children.children.indices where insert(&children.children[i].layout) {
                            node = .split(children)
                            return true
                        }
                    default: break
                    }
                    return false
                }
                #expect(insert(&value.layout))
            }
            return .init(tab: tab, pane: pane)
        case .resizeSplit:
            if ignoreWeights { return .init() }
            func resize(_ node: inout Wire.LayoutNode) {
                guard case .split(var split) = node else { return }
                if split.id == command.split {
                    #expect(split.children.count == command.weights!.count)
                    for i in split.children.indices { split.children[i].weight = command.weights![i] }
                } else {
                    for i in split.children.indices { resize(&split.children[i].layout) }
                }
                node = .split(split)
            }
            for tab in current.tabs { editTab(tab.id) { resize(&$0.layout) } }
            return .init()
        case .renameTab:
            editTab(command.tab!) { $0.name = command.name }
            return .init(tab: command.tab)
        case .group:
            let source = takeTab(command.tab!)
            let target = current.items.firstIndex { $0.id == command.target }!
            guard case .tab(let tab) = current.items[target] else { preconditionFailure("Expected standalone target") }
            let group = id()
            current.items[target] = .group(.init(id: group, name: "", tabs: [tab, source]))
            return .init(tab: source.id, group: group)
        case .move:
            let tab = takeTab(command.tab!)
            let i = current.items.firstIndex { $0.id == command.group }!
            guard case .group(var group) = current.items[i] else { preconditionFailure("Expected group") }
            group.tabs.append(tab)
            current.items[i] = .group(group)
            return .init(tab: tab.id, group: group.id)
        case .renameGroup:
            let i = current.items.firstIndex { $0.id == command.group }!
            guard case .group(var group) = current.items[i] else { preconditionFailure("Expected group") }
            group.name = command.name!
            current.items[i] = .group(group)
            return .init(group: group.id)
        case .closeTab:
            _ = takeTab(command.tab!)
            return .init(tab: command.tab)
        case .closePane:
            let tab = try #require(current.tabs.first { $0.pane(command.pane) != nil }?.id)
            editTab(tab) { value in
                value.panes.removeAll { $0.id == command.pane }
                func remove(_ node: inout Wire.LayoutNode) {
                    guard case .split(var split) = node else { return }
                    split.children.removeAll { $0.layout == .pane(command.pane!) }
                    for i in split.children.indices { remove(&split.children[i].layout) }
                    node = split.children.count == 1 ? split.children[0].layout : .split(split)
                }
                remove(&value.layout)
            }
            return .init(pane: command.pane)
        default: throw CocoaError(.featureUnsupported)
        }
    }

    /// Mutate a tab in place while preserving its top-level or group position.
    private func editTab(_ id: String, edit: (inout Wire.TabInfo) -> Void) {
        for i in current.items.indices {
            switch current.items[i] {
            case .tab(var tab) where tab.id == id:
                edit(&tab)
                current.items[i] = .tab(tab)
                return
            case .group(var group):
                if let j = group.tabs.firstIndex(where: { $0.id == id }) {
                    edit(&group.tabs[j])
                    current.items[i] = .group(group)
                    return
                }
            default: break
            }
        }
        Issue.record("No such fake tab: \(id)")
    }

    /// Remove a tab and prune only groups that become empty, as the core does.
    private func takeTab(_ id: String) -> Wire.TabInfo {
        let tab = current.tabs.first { $0.id == id }!
        current.items = current.items.compactMap { item in
            switch item {
            case .tab(let value): return value.id == id ? nil : item
            case .group(var group):
                group.tabs.removeAll { $0.id == id }
                return group.tabs.isEmpty ? nil : .group(group)
            }
        }
        return tab
    }
}
