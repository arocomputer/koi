import Foundation
import Observation

/// A reusable recipe for new shells, never a process or terminal-state backup.
/// IDs belong to the recipe and are mapped to fresh server IDs during restore.
struct Project: Codable, Equatable, Identifiable {
    /// One new shell's directory and optional user-authored startup source.
    struct Pane: Codable, Equatable, Identifiable {
        var id: String
        var cwd: String
        /// Only explicit user-authored shell source; never inferred from processes.
        var startup: String?
    }

    /// Ordered pane topology, independent of live server identities.
    indirect enum Node: Codable, Equatable {
        case pane(Pane)
        case split(Split)

        var panes: [Pane] {
            switch self {
            case .pane(let pane): [pane]
            case .split(let split): split.children.flatMap { $0.layout.panes }
            }
        }
    }

    /// A row or column whose child weights are relative to one another.
    struct Split: Codable, Equatable, Identifiable {
        /// A subtree and its share of the containing split.
        struct Child: Codable, Equatable {
            var layout: Node
            var weight: Double
        }
        var id: String
        var direction: Wire.Direction
        var children: [Child]
    }

    /// A named tab recreated with entirely new pane and split IDs.
    struct Tab: Codable, Equatable, Identifiable {
        var id: String
        var name: String?
        var layout: Node
    }

    /// A named, ordered collection of tabs, including singleton groups.
    struct Group: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var tabs: [Tab]
    }

    /// A top-level tab or group, preserving sidebar order.
    enum Item: Codable, Equatable {
        case tab(Tab)
        case group(Group)
    }

    var id: UUID
    var name: String
    /// SSH alias or user@host only; transport secrets and credentials are absent.
    var endpoint: Endpoint
    var items: [Item]

    var tabs: [Tab] {
        items.flatMap { item in
            switch item {
            case .tab(let tab): [tab]
            case .group(let group): group.tabs
            }
        }
    }

    /// Copies only names, topology, relative weights and directories. `startup`
    /// is an explicit per-pane override supplied by the caller, empty by default.
    init(snapshot: Wire.State, name: String, endpoint: Endpoint,
         startup: [String: String] = [:]) throws {
        id = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = endpoint
        items = try snapshot.items.map { item in
            switch item {
            case .tab(let tab): return .tab(try Self.capture(tab, startup: startup))
            case .group(let group):
                return .group(.init(id: group.id, name: group.name,
                                    tabs: try group.tabs.map { try Self.capture($0, startup: startup) }))
            }
        }
        try validate()
    }

    /// Reject malformed recipes before saving or creating any shells.
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectError("Give the project a name.")
        }
        guard !tabs.isEmpty else { throw ProjectError("The project has no tabs to recreate.") }
        var ids = Set<String>()
        func identity(_ id: String) throws {
            guard !id.isEmpty, ids.insert(id).inserted else {
                throw ProjectError("The project contains an empty or duplicate layout ID.")
            }
        }
        func node(_ layout: Node) throws {
            switch layout {
            case .pane(let pane): try identity(pane.id)
            case .split(let split):
                try identity(split.id)
                let weights = split.children.map(\.weight)
                guard weights.count >= 2, weights.allSatisfy({ $0.isFinite && $0 > 0 }),
                      weights.reduce(0, +).isFinite else {
                    throw ProjectError("Each split needs at least two children with finite positive weights.")
                }
                for child in split.children { try node(child.layout) }
            }
        }
        for item in items {
            if case .group(let group) = item {
                try identity(group.id)
                guard !group.tabs.isEmpty else { throw ProjectError("An empty group cannot be recreated.") }
            }
        }
        for tab in tabs {
            try identity(tab.id)
            try node(tab.layout)
        }
    }

    /// Whitelist shell recipe fields and reject inconsistent watcher snapshots.
    private static func capture(_ tab: Wire.TabInfo, startup: [String: String]) throws -> Tab {
        var seen = Set<String>()
        func node(_ layout: Wire.LayoutNode) throws -> Node {
            switch layout {
            case .pane(let id):
                guard let pane = tab.pane(id), seen.insert(id).inserted else {
                    throw ProjectError("Tab \(tab.id) has a missing or repeated pane in its layout.")
                }
                return .pane(.init(id: id, cwd: pane.cwd, startup: startup[id]))
            case .split(let split):
                return .split(.init(id: split.id, direction: split.direction,
                                    children: try split.children.map {
                                        .init(layout: try node($0.layout), weight: $0.weight)
                                    }))
            }
        }
        let layout = try node(tab.layout)
        guard seen.count == tab.panes.count else {
            throw ProjectError("Tab \(tab.id) has panes missing from its layout.")
        }
        return .init(id: tab.id, name: tab.name, layout: layout)
    }
}

/// User-presentable validation and persistence failures are never silently ignored.
private struct ProjectError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// One observable catalog per app; every mutation merges the latest file and
/// publishes only after an atomic write succeeds. Supply a temporary URL in tests.
@MainActor @Observable final class ProjectStore {
    private(set) var projects: [Project]
    let url: URL

    /// A missing file starts empty; unreadable or corrupt catalogs throw.
    init(url: URL = Paths.state.appendingPathComponent("projects.json")) throws {
        self.url = url
        projects = try Self.read(url)
    }

    /// Captures and appends a new named recipe with a stable catalog ID.
    @discardableResult
    func save(snapshot: Wire.State, name: String, endpoint: Endpoint,
              startup: [String: String] = [:]) throws -> Project {
        let project = try Project(snapshot: snapshot, name: name, endpoint: endpoint, startup: startup)
        try save(project)
        return project
    }

    /// Upserts by recipe ID, preserving other entries, including newer disk entries.
    func save(_ project: Project) throws {
        try project.validate()
        var next = try Self.read(url)
        if let index = next.firstIndex(where: { $0.id == project.id }) { next[index] = project }
        else { next.append(project) }
        try persist(next)
    }

    /// Changes only the display name; unknown IDs and blank names throw.
    func rename(_ id: UUID, to name: String) throws {
        var next = try Self.read(url)
        guard let index = next.firstIndex(where: { $0.id == id }) else {
            throw ProjectError("The project no longer exists.")
        }
        next[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try next[index].validate()
        try persist(next)
    }

    /// Removes only this recipe, without closing any live tabs or shells.
    func remove(_ id: UUID) throws {
        var next = try Self.read(url)
        guard let index = next.firstIndex(where: { $0.id == id }) else {
            throw ProjectError("The project no longer exists.")
        }
        next.remove(at: index)
        try persist(next)
    }

    /// Treat only an absent file as empty; never overwrite malformed entries.
    private static func read(_ url: URL) throws -> [Project] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let projects = try JSONDecoder().decode([Project].self, from: data)
        guard Set(projects.map(\.id)).count == projects.count else {
            throw ProjectError("The project file contains duplicate project IDs.")
        }
        for project in projects { try project.validate() }
        return projects
    }

    /// Commit the complete catalog atomically before notifying observers.
    private func persist(_ next: [Project]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        projects = next
    }
}

/// Recreates a recipe on the endpoint chosen by the caller. The injected command
/// adapter must complete or throw on disconnect; state must read its watcher.
/// Use one restorer per workspace. Existing tabs and jobs are never reused.
@MainActor final class ProjectRestorer {
    /// Context for displaying a stopped restore and inspecting its new tabs.
    struct Failure: LocalizedError {
        let project: String
        let operation: String
        let reason: String
        /// Fresh tabs left for inspection, including any unfinished helper tab.
        let createdTabs: [String]
        var errorDescription: String? {
            "Could not open project ‘\(project)’ while \(operation): \(reason) "
                + "Existing jobs were preserved. \(createdTabs.count) new tab(s) were left for inspection."
        }
    }

    private let command: @MainActor (Wire.Command) async throws -> Wire.Result
    private let state: @MainActor () -> Wire.State
    private let select: @MainActor (String) -> Void
    private let stateTimeout: Duration
    private var restoring = false
    private var createdTabs: [String] = []
    private var panes: [String: String] = [:]
    private var operation = "validating the layout"

    /// Bind all three closures to the workspace for the recipe's endpoint.
    init(command: @escaping @MainActor (Wire.Command) async throws -> Wire.Result,
         state: @escaping @MainActor () -> Wire.State,
         select: @escaping @MainActor (String) -> Void,
         stateTimeout: Duration = .seconds(3)) {
        self.command = command
        self.state = state
        self.select = select
        self.stateTimeout = stateTimeout
    }

    /// Returns fresh tab IDs in recipe order and selects the first only after
    /// success. Failure stops immediately, leaving all unfinished work inspectable.
    @discardableResult
    func restore(_ project: Project) async throws -> [String] {
        guard !restoring else { throw ProjectError("A project is already opening on this workspace.") }
        restoring = true
        createdTabs = []
        panes = [:]
        operation = "validating the layout"
        defer { restoring = false }
        do {
            try project.validate()
            var tabs: [String] = []
            for item in project.items {
                switch item {
                case .tab(let tab): tabs.append(try await restoreTab(tab))
                case .group(let group):
                    var members: [String] = []
                    for tab in group.tabs { members.append(try await restoreTab(tab)) }
                    // Native grouping requires two tabs. A private helper makes
                    // singleton groups possible without borrowing an existing tab.
                    var helper: String?
                    if members.count == 1 {
                        let pane = group.tabs[0].layout.panes[0]
                        helper = try await newTab(cwd: pane.cwd, startup: nil).tab
                        members.append(helper!)
                    }
                    let result = try await send(.init(op: .group, tab: members[1], target: members[0]),
                                                "creating group ‘\(group.name)’")
                    guard let id = result.group else { throw ProjectError("The server returned no group ID.") }
                    _ = try await wait("waiting for group \(id)") { state in
                        state.items.contains { item in
                            if case .group(let g) = item { return g.id == id && g.tabs.map(\.id) == Array(members.prefix(2)) }
                            return false
                        } ? true : nil
                    }
                    for member in members.dropFirst(2) {
                        _ = try await send(.init(op: .move, tab: member, group: id), "adding a tab to group ‘\(group.name)’")
                    }
                    _ = try await send(.init(op: .renameGroup, group: id, name: group.name), "naming group ‘\(group.name)’")
                    if let helper {
                        _ = try await send(.init(op: .closeTab, tab: helper), "removing the temporary grouping tab")
                        members.removeLast()
                    }
                    _ = try await wait("waiting for group ‘\(group.name)’") { state in
                        state.items.contains { item in
                            if case .group(let g) = item {
                                return g.id == id && g.name == group.name && g.tabs.map(\.id) == members
                            }
                            return false
                        } ? true : nil
                    }
                    if let helper { createdTabs.removeAll { $0 == helper } }
                    tabs.append(contentsOf: members)
                }
            }
            try Task.checkCancellation()
            if let first = tabs.first { select(first) }
            return tabs
        } catch {
            throw Failure(project: project.name, operation: operation,
                          reason: error.localizedDescription, createdTabs: createdTabs)
        }
    }

    /// Finish one new tab before starting another, retaining its ID on failure.
    private func restoreTab(_ tab: Project.Tab) async throws -> String {
        let first = tab.layout.panes[0]
        let fresh = try await newTab(cwd: first.cwd, startup: first.startup)
        panes[first.id] = fresh.pane
        try await build(tab.layout, anchor: fresh.pane, tab: fresh.tab, parent: nil)
        let layout = try await wait("waiting for tab \(fresh.tab)'s pane topology") { state in
            guard let live = state.tabs.first(where: { $0.id == fresh.tab }), matches(tab.layout, live.layout) else { return nil as Wire.LayoutNode? }
            return live.layout
        }
        try await resize(tab.layout, live: layout, tab: fresh.tab)
        if let name = tab.name {
            _ = try await send(.init(op: .renameTab, tab: fresh.tab, name: name), "naming tab ‘\(name)’")
            _ = try await wait("waiting for tab name ‘\(name)’") { state in
                state.tabs.first { $0.id == fresh.tab && $0.name == name }
            }
        }
        return fresh.tab
    }

    /// Append at the top level, then resolve the initial shell through watcher state.
    private func newTab(cwd: String, startup: String?) async throws -> (tab: String, pane: String) {
        let before = state()
        let result = try await send(.init(op: .newTab, cwd: cwd, startup: startup), "starting a new shell in \(cwd)")
        guard let tab = result.tab, !tab.isEmpty, !before.tabs.contains(where: { $0.id == tab }) else {
            throw ProjectError("The server did not return a fresh tab ID.")
        }
        createdTabs.append(tab)
        let live: Wire.TabInfo = try await wait("waiting for new tab \(tab)") { state in
            state.tabs.first { $0.id == tab && $0.panes.count == 1 }
        }
        guard case .pane(let pane) = live.layout,
              live.panes[0].id == pane, result.pane == nil || result.pane == pane,
              !before.tabs.flatMap(\.panes).contains(where: { $0.id == pane }) else {
            throw ProjectError("The new tab did not contain one fresh shell.")
        }
        return (tab, pane)
    }

    /// Creates siblings before descending, so native insertion produces the
    /// saved order. A perpendicular helper prevents same-direction flattening.
    private func build(_ node: Project.Node, anchor: String, tab: String, parent: Wire.Direction?) async throws {
        guard case .split(let split) = node else { return }
        var helper: String?
        if split.direction == parent {
            helper = try await splitPane(anchor, direction: split.direction == .right ? .down : .right,
                                         pane: .init(id: "", cwd: node.panes[0].cwd), tab: tab)
        }
        var anchors = [anchor]
        for child in split.children.dropFirst() {
            let first = child.layout.panes[0]
            let id = try await splitPane(anchors.last!, direction: split.direction, pane: first, tab: tab)
            panes[first.id] = id
            anchors.append(id)
        }
        for (child, id) in zip(split.children, anchors) {
            try await build(child.layout, anchor: id, tab: tab, parent: split.direction)
        }
        if let helper {
            _ = try await send(.init(op: .closePane, pane: helper), "removing a temporary topology pane")
            _ = try await wait("waiting for the temporary pane to close") { state in
                state.tabs.first { $0.id == tab && $0.pane(helper) == nil }
            }
        }
    }

    /// Add one fresh shell beside a pane owned by this restore.
    private func splitPane(_ anchor: String, direction: Wire.Direction, pane: Project.Pane, tab: String) async throws -> String {
        let before = Set(state().tabs.flatMap(\.panes).map(\.id))
        let result = try await send(.init(op: .splitPane, pane: anchor, direction: direction,
                                         cwd: pane.cwd, startup: pane.startup), "starting a split shell in \(pane.cwd)")
        guard let id = result.pane, !id.isEmpty, !before.contains(id), result.tab == nil || result.tab == tab else {
            throw ProjectError("The server did not return a fresh pane in the new tab.")
        }
        _ = try await wait("waiting for new pane \(id)") { state in
            state.tabs.first { $0.id == tab && $0.pane(id) != nil && $0.layout.panes.contains(id) }
        }
        return id
    }

    /// Match topology using the recipe-to-server pane map, ignoring split IDs.
    private func matches(_ saved: Project.Node, _ live: Wire.LayoutNode) -> Bool {
        switch (saved, live) {
        case (.pane(let pane), .pane(let id)): return panes[pane.id] == id
        case (.split(let a), .split(let b)):
            return a.direction == b.direction && a.children.count == b.children.count
                && zip(a.children, b.children).allSatisfy { matches($0.layout, $1.layout) }
        default: return false
        }
    }

    /// One exact vector per split; never approximate through divider ratios.
    private func resize(_ saved: Project.Node, live: Wire.LayoutNode, tab: String) async throws {
        guard case .split(let a) = saved, case .split(let b) = live else { return }
        let weights = a.children.map(\.weight)
        var command = Wire.Command(op: .resizeSplit, split: b.id)
        command.weights = weights
        _ = try await send(command, "restoring split \(a.id)'s weights")
        _ = try await wait("waiting for split \(b.id)'s exact weights") { state in
            func find(_ node: Wire.LayoutNode) -> Wire.LayoutNode.Split? {
                guard case .split(let split) = node else { return nil }
                if split.id == b.id { return split }
                return split.children.lazy.compactMap { find($0.layout) }.first
            }
            guard let layout = state.tabs.first(where: { $0.id == tab })?.layout,
                  let split = find(layout), matches(saved, .split(split)) else { return nil as Bool? }
            let actual = split.children.map(\.weight)
            let total = actual.reduce(0, +), expected = weights.reduce(0, +)
            return actual.allSatisfy { $0.isFinite && $0 > 0 } && total.isFinite
                && zip(actual, weights).allSatisfy { abs($0 / total - $1 / expected) <= 1e-9 } ? true : nil
        }
        for (child, liveChild) in zip(a.children, b.children) {
            try await resize(child.layout, live: liveChild.layout, tab: tab)
        }
    }

    /// Await one adapter result and turn command errors into contextual failures.
    private func send(_ command: Wire.Command, _ description: String) async throws -> Wire.Result {
        operation = description
        try Task.checkCancellation()
        let result = try await self.command(command)
        if let error = result.error { throw ProjectError(error) }
        return result
    }

    /// Watcher delivery can follow the command result; every wait has a deadline
    /// and cancellation, and returns the exact state value that met its predicate.
    private func wait<T>(_ description: String, read: (Wire.State) -> T?) async throws -> T {
        operation = description
        let deadline = ContinuousClock.now.advanced(by: stateTimeout)
        while true {
            try Task.checkCancellation()
            if let value = read(state()) { return value }
            guard ContinuousClock.now < deadline else {
                throw ProjectError("Timed out waiting for server state. The server may not support this layout operation.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
