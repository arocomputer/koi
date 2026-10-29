import AppKit
import Observation

/// A server rejection or bounded command timeout suitable for display to users.
struct WorkspaceCommandError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The app's view of the server's tree, and what the user has selected in
/// it. The server is the source of truth for tabs, groups and panes; the
/// workspace mirrors it, keeps one attached view per pane (so switching tabs
/// is instant and hidden tabs stay current), and remembers what is only this
/// app's: the selected tab, collapsed groups, and tabs that finished
/// something out of sight.
@MainActor @Observable
final class Workspace {
    /// The machine whose server this mirrors.
    let endpoint: Endpoint
    private let controller = UUID().uuidString
    /// Creation recipes can build their own new panes before a view attaches.
    /// The server still checks the creation reservation or current owner.
    @ObservationIgnored private var createdPanes: Set<String> = []
    private(set) var state = Wire.State()
    private(set) var transport: DiagnosticServer.Transport = .disconnected
    private(set) var selectedTab: String?
    /// Tabs whose program finished while they were not selected.
    private(set) var attention: Set<String> = []
    private(set) var collapsed: Set<String> = []
    /// The group whose name field is open.
    var renamingGroup: String?
    var renamingTab: String?
    /// Submitted names remain visible until the server publishes them or rejects the command.
    private(set) var pendingTabNames: [String: String] = [:]
    @ObservationIgnored private var tabRenameIDs: [String: UUID] = [:]
    @ObservationIgnored private var confirmedTabRenames: [String: UUID] = [:]
    private(set) var pendingGroupNames: [String: String] = [:]
    @ObservationIgnored private var groupRenameIDs: [String: UUID] = [:]
    @ObservationIgnored private var confirmedGroupRenames: [String: UUID] = [:]

    /// Called when the selected tab, its layout or its focused pane
    /// changes, to show it.
    @ObservationIgnored var onShow: ((Wire.TabInfo?) -> Void)?
    @ObservationIgnored var onViewsChanged: (() -> Void)?
    /// Every rejected command, including attempts while offline, reaches the owner.
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored var onConnected: (() -> Void)?
    @ObservationIgnored var serverCapabilities: Set<String>?
    /// The pane with the keyboard in the selected tab.
    private(set) var focusedPane: String?
    /// The pane shown alone in its tab, if any.
    private(set) var zoomedPane: String?
    @ObservationIgnored private var focusByTab: [String: String] = [:]
    @ObservationIgnored private var shown: (tab: String, layout: Wire.LayoutNode, focus: String?, zoom: String?, panes: [Wire.PaneInfo])?
    /// Called once the last tab is gone.
    @ObservationIgnored var onEmpty: (() -> Void)?

    @ObservationIgnored private var control: Control?
    @ObservationIgnored private var controlTransport: Transport?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectSignal: UUID?
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var reconnectDelay: UInt64 = 300_000_000
    @ObservationIgnored private var connectionDeadline: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var views: [String: TerminalView] = [:]
    @ObservationIgnored private var fontSize = Config.current.fontSize
    @ObservationIgnored private var received = false
    @ObservationIgnored private var pendingSelection: String?
    /// When each working tab started working.
    @ObservationIgnored private var workingSince: [String: Date] = [:]

    init(_ endpoint: Endpoint, control: Control? = nil, controlTransport: Transport? = nil) {
        self.endpoint = endpoint
        self.control = control
        self.controlTransport = controlTransport
    }

    isolated deinit {
        reconnectTask?.cancel()
        connectionDeadline?.cancel()
        connecting?.cancel()
        control?.close()
        views.values.forEach { $0.detach() }
    }

    func start() {
        collapsed = Set(layout.collapsed)
        running = true
        connectControl()
    }

    /// A connection attempt never blocks pane input or window animation.
    /// Its generation prevents a detached workspace accepting a late socket.
    private func connectControl() {
        guard running, connecting == nil else { return }
        let endpoint = endpoint, generation = UUID()
        connectionGeneration = generation
        connecting = Task { [weak self] in
            let socket = await endpoint.connectAsync()
            guard let self, !Task.isCancelled, self.running, self.connectionGeneration == generation else {
                socket?.close()
                return
            }
            self.connecting = nil
            guard let socket else {
                if !self.received { self.onError?("Could not connect to this machine. Retrying…") }
                self.reconnectControl()
                return
            }
            let c = Control(socket: socket)
            var initialized = false
            let tabsAwaitingReconnect = self.confirmedTabRenames
            let groupsAwaitingReconnect = self.confirmedGroupRenames
            self.stopAwaitingServer()
            self.control = c
            self.controlTransport = socket
            self.transport = endpoint == .local ? .localSocket : (c.usesEncryptedLink ? .encryptedUDP : .sshRelay)
            self.serverCapabilities = nil
            self.onConnected?()
            c.onState = { [weak self, weak c] state in
                guard let self, let c, self.control === c else { return }
                let firstState = !initialized
                initialized = true
                self.connectionDeadline?.cancel()
                self.connectionDeadline = nil
                self.reconnectDelay = 300_000_000
                self.apply(state)
                if firstState {
                    for (id, request) in tabsAwaitingReconnect { self.retireTabRename(id, request: request) }
                    for (id, request) in groupsAwaitingReconnect { self.retireGroupRename(id, request: request) }
                }
            }
            c.onError = { [weak self, weak c] message in
                guard let self, let c, self.control === c else { return }
                self.onError?("Cannot read this machine’s state: \(message)")
                if !initialized { Remote.connectionFailed(endpoint, transport: socket) }
                c.close()
                self.reconnectControl()
            }
            c.onDisconnect = { [weak self, weak c] in
                guard let self, let c, self.control === c else { return }
                if !initialized { Remote.connectionFailed(endpoint, transport: socket) }
                self.reconnectControl()
            }
            self.connectionDeadline?.cancel()
            self.connectionDeadline = Task { [weak self, weak c] in
                var deadline = ConnectionDeadline(now: ProcessInfo.processInfo.systemUptime)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, let c, self.control === c, !initialized else { return }
                    if deadline.stalled(receivedBytes: c.receivedBytes, now: ProcessInfo.processInfo.systemUptime) {
                        Remote.connectionFailed(endpoint, transport: socket)
                        self.onError?("This machine stopped sending its state. Reconnecting…")
                        c.close()
                        self.reconnectControl()
                        return
                    }
                }
            }
        }
    }

    /// A temporary transport loss must not leave the sidebar frozen. Keep
    /// the current tree while reconnecting, then replace it with fresh state.
    private func reconnectControl() {
        connectionDeadline?.cancel()
        connectionDeadline = nil
        control = nil
        controlTransport = nil
        transport = .disconnected
        onViewsChanged?()
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 5_000_000_000)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.running else { return }
            self.reconnectTask = nil
            self.connectControl()
        }
        // A server appearing or the network changing is tried at once.
        if reconnectSignal == nil {
            reconnectSignal = Reconnect.observe { [weak self] in
                guard let self, self.running else { return }
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                self.connectControl()
            }
        }
    }

    private func stopAwaitingServer() {
        if let reconnectSignal { Reconnect.stopObserving(reconnectSignal) }
        reconnectSignal = nil
    }

    /// Detaches every pane, leaving their shells running.
    func detachAll() {
        running = false
        stopAwaitingServer()
        reconnectTask?.cancel()
        connectionDeadline?.cancel()
        connectionDeadline = nil
        reconnectTask = nil
        connecting?.cancel()
        connecting = nil
        connectionGeneration = UUID()
        views.values.forEach { $0.detach() }
        views.removeAll()
        onViewsChanged?()
        control?.close()
        control = nil
        controlTransport = nil
        transport = .disconnected
    }

    var selectedView: TerminalView? {
        selectedPane.map { view(for: $0.id) }
    }

    /// The focused pane of the selected tab.
    var selectedPane: Wire.PaneInfo? {
        guard let t = tab(selectedTab)?.tab else { return nil }
        return t.pane(focusedPane) ?? t.panes.first
    }

    /// The pane a tab's row and title stand for: the one focused there.
    func focusedPane(in t: Wire.TabInfo) -> Wire.PaneInfo? {
        t.pane(focusByTab[t.id]) ?? t.pane(t.layout.panes.first) ?? t.panes.first
    }

    /// The tab and the group it is in, if any.
    func tab(_ id: String?) -> (tab: Wire.TabInfo, group: Wire.GroupInfo?)? {
        for item in state.items {
            switch item {
            case .tab(let t): if t.id == id { return (t, nil) }
            case .group(let g): if let t = g.tabs.first(where: { $0.id == id }) { return (t, g) }
            }
        }
        return nil
    }

    /// Accept an authoritative tree, resolving removal and selection together.
    func apply(_ new: Wire.State) {
        let previousLive = Set(state.tabs.flatMap { $0.layout.panes })
        createdPanes.subtract(previousLive.subtracting(new.tabs.flatMap { $0.layout.panes }))
        let previousTabs = state.tabs.map(\.id)
        let previousPanes = tab(selectedTab)?.tab.layout.panes ?? []
        let first = !received
        received = true
        // A tab that worked for a while and stopped while out of sight wants
        // attention; a brief burst of output does not.
        for t in new.tabs {
            let working = t.panes.contains { $0.status == .working }
            if working {
                if workingSince[t.id] == nil { workingSince[t.id] = Date() }
            } else if let since = workingSince.removeValue(forKey: t.id),
                      t.id != selectedTab, Date().timeIntervalSince(since) >= 3 {
                attention.insert(t.id)
            }
        }
        state = new
        let names = Dictionary(uniqueKeysWithValues: new.tabs.map { ($0.id, $0.name ?? "") })
        for (id, name) in pendingTabNames where names[id] == nil || names[id] == name {
            pendingTabNames[id] = nil
            tabRenameIDs[id] = nil
            confirmedTabRenames[id] = nil
        }
        let groupNames = Dictionary(uniqueKeysWithValues: new.items.compactMap { item -> (String, String)? in
            if case .group(let group) = item { return (group.id, group.name) }
            return nil
        })
        for (id, name) in pendingGroupNames where groupNames[id] == nil || groupNames[id] == name {
            pendingGroupNames[id] = nil
            groupRenameIDs[id] = nil
            confirmedGroupRenames[id] = nil
        }

        let live = Set(new.tabs.flatMap(\.panes).map(\.id))
        for (id, view) in views where !live.contains(id) {
            view.detach()
            views[id] = nil
        }
        onViewsChanged?()
        for pane in new.tabs.flatMap(\.panes) { views[pane.id]?.setProgram(pane.program) }
        attention.formIntersection(Set(new.tabs.map(\.id)))

        if new.items.isEmpty {
            if first {
                newTab()
            } else {
                selectedTab = nil
                focusedPane = nil
                zoomedPane = nil
                shown = nil
                onShow?(nil)
                onEmpty?()
            }
            return
        }
        if let p = pendingSelection, tab(p) != nil {
            pendingSelection = nil
            select(p)
        } else if tab(selectedTab) == nil {
            let saved = first ? layout.tab : nil
            // Prefer the former left neighbor, then the right, after removal.
            // Selection and strip topology now change in the same observation.
            let live = Set(new.tabs.map(\.id))
            let index = previousTabs.firstIndex { $0 == selectedTab } ?? 0
            let neighbor = previousTabs.prefix(index).reversed().first(where: live.contains)
                ?? previousTabs.dropFirst(index + 1).first(where: live.contains)
            select(tab(saved) != nil ? saved : neighbor ?? new.tabs.first?.id)
        } else {
            if let t = tab(selectedTab)?.tab, t.pane(focusedPane) == nil {
                let live = Set(t.layout.panes)
                let index = previousPanes.firstIndex { $0 == focusedPane } ?? 0
                focusedPane = previousPanes.prefix(index).reversed().first(where: live.contains)
                    ?? previousPanes.dropFirst(index + 1).first(where: live.contains)
            }
            show()
        }
    }

    /// Shows the selected tab if what it shows has changed: a pane came or
    /// went, a split moved, the focus or zoom changed.
    private func show() {
        guard let t = tab(selectedTab)?.tab else { return }
        if t.pane(focusedPane) == nil { focusedPane = focusedPane(in: t)?.id }
        if let z = zoomedPane, t.pane(z) == nil || z != focusedPane { zoomedPane = nil }
        if let f = focusedPane { focusByTab[t.id] = f }
        // The panes themselves are part of what is shown: a program starting
        // or a title changing refreshes the headers, not only layout or focus.
        let now = (t.id, t.layout, focusedPane, zoomedPane, t.panes)
        if let s = shown, s.tab == now.0, s.layout == now.1, s.focus == now.2, s.zoom == now.3, s.panes == now.4 { return }
        shown = now
        onShow?(t)
    }

    func select(_ tabID: String?) {
        guard let tabID, let t = tab(tabID)?.tab else { return }
        selectedTab = tabID
        focusedPane = focusedPane(in: t)?.id
        zoomedPane = nil
        attention.remove(tabID)
        show()
        saveLayout()
    }

    /// Gives a pane the keyboard and reveals it in the same presentation update.
    func focus(_ pane: String) {
        guard let t = tab(selectedTab)?.tab, t.pane(pane) != nil, pane != focusedPane else { return }
        focusedPane = pane
        if let zoomedPane, zoomedPane != pane { self.zoomedPane = nil }
        show()
    }

    /// Focuses the pane `offset` places after the focused one, in reading
    /// order, wrapping.
    func focusPane(offset: Int) {
        guard let t = tab(selectedTab)?.tab else { return }
        let panes = t.layout.panes
        guard panes.count > 1 else { return }
        let i = panes.firstIndex { $0 == focusedPane } ?? 0
        focus(panes[(i + offset + panes.count) % panes.count])
    }

    func toggleZoom() {
        guard let t = tab(selectedTab)?.tab, t.panes.count > 1 || zoomedPane != nil else { return }
        zoomedPane = zoomedPane == nil ? focusedPane : nil
        show()
    }

    /// Selects the tab `offset` places after the selected one, wrapping.
    func selectTab(offset: Int) {
        let tabs = state.tabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == selectedTab } ?? 0
        select(tabs[(i + offset + tabs.count) % tabs.count].id)
    }

    /// Selects the nth tab from the top, counting from 1.
    func selectTab(number n: Int) {
        let tabs = state.tabs
        guard n >= 1, !tabs.isEmpty else { return }
        select(tabs[min(n, tabs.count) - 1].id)
    }

    func toggleCollapsed(_ group: String) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
        saveLayout()
    }

    /// This machine's part of what the app remembers.
    private var layout: Layout.Machine {
        Layout.load().machines[endpoint.key] ?? Layout.Machine()
    }

    private func saveLayout() {
        var all = Layout.load()
        all.machines[endpoint.key] = Layout.Machine(tab: selectedTab, collapsed: Array(collapsed))
        all.save()
    }

    // MARK: Commands

    /// Async workflows retain Control's FIFO while bounding a stalled server.
    /// Reply ownership is single-use so disconnect and timeout cannot resume twice.
    func perform(_ command: Wire.Command, reportingErrors: Bool = true) async throws -> Wire.Result {
        guard let control else { throw WorkspaceCommandError("Machine is offline") }
        if let error = observationError(for: command) {
            if reportingErrors { onError?(error) }
            throw WorkspaceCommandError(error)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = CommandReply(continuation)
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if reportingErrors { self?.onError?("The server did not answer this command.") }
                reply.finish(.failure(WorkspaceCommandError("The server did not answer this command.")))
            }
            var ownedCommand = command
            ownedCommand.controller = controller
            control.send(ownedCommand) { [weak self] result in
                timeout.cancel()
                if let error = result.error {
                    if reportingErrors { self?.onError?(error) }
                    reply.finish(.failure(WorkspaceCommandError(error)))
                } else {
                    self?.recordCreation(command, result: result)
                    reply.finish(.success(result))
                }
            }
        }
    }

    private final class CommandReply {
        private var continuation: CheckedContinuation<Wire.Result, any Error>?
        init(_ continuation: CheckedContinuation<Wire.Result, any Error>) { self.continuation = continuation }
        func finish(_ result: Result<Wire.Result, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    /// Keep Control's FIFO and completion semantics while reporting all errors.
    /// Offline commands complete too, so gesture owners can release their state.
    private func send(_ command: Wire.Command, done: @escaping @MainActor (Wire.Result) -> Void = { _ in }) {
        let completion: @MainActor (Wire.Result) -> Void = { [weak self] result in
            if let error = result.error { self?.onError?(error) }
            self?.recordCreation(command, result: result)
            done(result)
        }
        guard let control else { completion(.init(error: "Machine is offline")); return }
        if let error = observationError(for: command) { completion(.init(error: error)); return }
        var ownedCommand = command
        ownedCommand.controller = controller
        control.send(ownedCommand, done: completion)
    }

    /// Retain only panes returned by this client's successful creation requests.
    private func recordCreation(_ command: Wire.Command, result: Wire.Result) {
        guard result.error == nil, command.op == .newTab || command.op == .splitPane,
              let pane = result.pane else { return }
        createdPanes.insert(pane)
    }

    /// Observation protects existing work from destructive and terminal-edit
    /// actions as well as PTY input. Inspect cached views only; never attach to
    /// decide whether a command is allowed.
    private func observationError(for command: Wire.Command) -> String? {
        func splitPanes(_ node: Wire.LayoutNode, id: String?) -> [String] {
            guard case .split(let split) = node else { return [] }
            if split.id == id { return node.panes }
            return split.children.flatMap { splitPanes($0.layout, id: id) }
        }
        let targets: [String]
        switch command.op {
        case .closePane, .clearPane, .resetPane, .configurePane, .splitPane:
            targets = command.pane.map { [$0] } ?? []
        case .closeTab:
            targets = tab(command.tab)?.tab.layout.panes ?? []
        case .closeGroup:
            targets = state.items.flatMap { item -> [String] in
                if case .group(let group) = item, group.id == command.group { return group.tabs.flatMap { $0.layout.panes } }
                return []
            }
        case .swapPanes:
            targets = [command.pane, command.target].compactMap { $0 }
        case .resizeSplit:
            targets = state.tabs.flatMap { splitPanes($0.layout, id: command.split) }
        default: return nil
        }
        let blocked = targets.contains { id in
            if createdPanes.contains(id) { return false }
            guard let view = views[id] else { return endpoint != .local }
            return view.observing || (endpoint != .local && !view.canControl)
        }
        return blocked ? "Take Control of the affected panes before changing or closing them. Their processes are still running." : nil
    }

    /// A new tab after the selected one, in its group if it has one,
    /// starting in the selected pane's directory.
    func newTab() {
        if !prepareStartup(retry: { [weak self] in self?.newTab() }) { return }
        var c = Wire.Command(op: .newTab, tab: selectedTab, cwd: selectedPane?.cwd)
        c.startup = Config.current.startupCommand.isEmpty ? nil : Config.current.startupCommand
        if serverCapabilities?.contains("configurePane") == true { c.appearance = ServerInspector.appearance }
        let size = selectedPane.flatMap { views[$0.id]?.currentGridSize }
        c.cols = size?.cols
        c.rows = size?.rows
        c.cellWidth = size?.cellWidth
        c.cellHeight = size?.cellHeight
        send(c) { [weak self] result in
            guard let self, result.error == nil, let tab = result.tab else { return }
            // The tree may not have the tab yet; `apply` selects it then.
            if self.tab(tab) != nil { self.select(tab) } else { self.pendingSelection = tab }
        }
    }

    /// Swaps two panes' positions in the tab, for dragging one header onto
    /// another.
    func swapPanes(_ dragged: String, onto target: String) {
        guard dragged != target else { return }
        send(.init(op: .swapPanes, pane: dragged, target: target))
    }

    func splitPane(_ direction: Wire.Direction) {
        guard let pane = selectedPane else { return }
        if !prepareStartup(retry: { [weak self] in self?.splitPane(direction) }) { return }
        var c = Wire.Command(op: .splitPane, pane: pane.id, direction: direction)
        c.startup = Config.current.startupCommand.isEmpty ? nil : Config.current.startupCommand
        if serverCapabilities?.contains("configurePane") == true { c.appearance = ServerInspector.appearance }
        let size = selectedPane.flatMap { views[$0.id]?.currentGridSize }
        c.cols = size.map { $0.cols / (direction == .right ? 2 : 1) }
        c.rows = size.map { $0.rows / (direction == .down ? 2 : 1) }
        c.cellWidth = size?.cellWidth
        c.cellHeight = size?.cellHeight
        send(c) { [weak self] result in
            guard let self, result.error == nil, let id = result.pane else { return }
            self.zoomedPane = nil
            self.focusedPane = id
            if let t = self.tab(self.selectedTab)?.tab, t.pane(id) != nil { self.show() }
        }
    }

    /// Older additive-v6 servers ignore unknown creation fields. Require an
    /// advertised capability so a requested startup command is never ignored.
    private func prepareStartup(retry: @escaping @MainActor () -> Void) -> Bool {
        guard !Config.current.startupCommand.isEmpty else { return true }
        if let serverCapabilities {
            if serverCapabilities.contains("startup") { return true }
            onError?("Update the running server to use a startup command. Existing sessions were preserved.")
            return false
        }
        guard let control else { onError?("Machine is offline"); return false }
        control.send(.init(op: .serverInfo)) { [weak self] result in
            guard let self else { return }
            self.serverCapabilities = Set(result.capabilities ?? [])
            if result.supports("startup") { retry() }
            else { self.onError?("Update the running server to use a startup command. Existing sessions were preserved.") }
        }
        return false
    }

    /// Closes the focused pane; the tab goes with its last pane.
    func closePane() {
        guard let pane = selectedPane, let t = tab(selectedTab)?.tab else { return }
        if t.panes.count <= 1 { return closeTab() }
        // Resolve focus with the removal, preserving it if the close fails.
        send(.init(op: .closePane, pane: pane.id))
    }

    func resizeSplit(_ id: String, index: Int, ratio: Double) {
        // Binary v6 splits only have the default divider; keep their original
        // command shape while addressing later dividers on weighted servers.
        send(.init(op: .resizeSplit, split: id, ratio: ratio, index: index == 0 ? nil : index))
    }

    func closeTab(_ id: String? = nil) {
        guard let id = id ?? selectedTab else { return }
        // Wait for the authoritative removal: preselecting a neighbor makes
        // the highlight chase its old slot before that slot shifts left.
        send(.init(op: .closeTab, tab: id))
    }

    func closeGroup(_ id: String) {
        send(.init(op: .closeGroup, group: id))
    }

    func ungroup(_ id: String) {
        send(.init(op: .ungroup, group: id))
    }

    /// Keep a submitted name visible while the authoritative group update is in flight.
    func renameGroup(_ id: String, to name: String) {
        let request = UUID()
        pendingGroupNames[id] = name
        groupRenameIDs[id] = request
        confirmedGroupRenames[id] = nil
        send(.init(op: .renameGroup, group: id, name: name)) { [weak self] result in
            guard let self, self.groupRenameIDs[id] == request else { return }
            if result.error != nil { self.retireGroupRename(id, request: request); return }
            self.confirmedGroupRenames[id] = request
            self.refreshNames { [weak self] in self?.retireGroupRename(id, request: request) }
        }
    }

    /// Keep a submitted name visible until watcher confirmation or command rejection.
    func renameTab(_ id: String, to name: String) {
        let request = UUID()
        pendingTabNames[id] = name
        tabRenameIDs[id] = request
        confirmedTabRenames[id] = nil
        send(.init(op: .renameTab, tab: id, name: name)) { [weak self] result in
            guard let self, self.tabRenameIDs[id] == request else { return }
            if result.error != nil { self.retireTabRename(id, request: request); return }
            self.confirmedTabRenames[id] = request
            self.refreshNames { [weak self] in self?.retireTabRename(id, request: request) }
        }
    }

    /// A watch followed by a command reply fences coalesced state callbacks.
    /// The serverInfo error on older servers is still a valid ordered reply.
    private func refreshNames(_ complete: @escaping @MainActor () -> Void) {
        guard let control, let controlTransport else { return }
        controlTransport.send(.watch)
        control.send(.init(op: .serverInfo)) { [weak self, weak control] result in
            guard let self, let control, self.control === control,
                  result.error != "connection closed", result.error != "connection unavailable" else { return }
            complete()
        }
    }

    /// Retire only the request whose reply or reconnect snapshot is being reconciled.
    private func retireTabRename(_ id: String, request: UUID) {
        guard tabRenameIDs[id] == request else { return }
        pendingTabNames[id] = nil
        tabRenameIDs[id] = nil
        confirmedTabRenames[id] = nil
    }

    private func retireGroupRename(_ id: String, request: UUID) {
        guard groupRenameIDs[id] == request else { return }
        pendingGroupNames[id] = nil
        groupRenameIDs[id] = nil
        confirmedGroupRenames[id] = nil
    }

    /// Closes every tab but this one; a target that has closed does nothing.
    func closeOtherTabs(_ keep: String) {
        guard tab(keep) != nil else { return }
        for id in state.tabs.map(\.id) where id != keep { closeTab(id) }
    }

    /// Explicitly group two tabs, opening the name field for a new group.
    /// Existing target groups receive the source without starting a rename.
    func drop(_ dragged: String, onto target: String) {
        guard dragged != target, let found = tab(target) else { return }
        let makesGroup = found.group == nil
        send(.init(op: .group, tab: dragged, target: target)) { [weak self] result in
            guard let self, result.error == nil, makesGroup, let group = result.group else { return }
            self.collapsed.remove(group)
            self.renamingGroup = group
        }
    }

    /// Join a named group at its end from the tab's explicit grouping menu.
    func drop(_ dragged: String, intoGroup group: String) {
        send(.init(op: .move, tab: dragged, group: group))
    }

    /// A tab dropped before or after another: reorder it into that slot, within
    /// the target's group or the top-level list. The index is computed against
    /// the list with the dragged tab removed, since the server takes it out
    /// before inserting. The top-level list counts groups too, since that is
    /// what the server inserts into.
    func reorder(_ dragged: String, to target: String, after: Bool) {
        guard let command = moveCommand(dragged, to: target, after: after, outside: false) else { return }
        send(command)
    }

    /// Commit a strip insertion once, after release. Explicit group boundaries
    /// let every placement move a tab out of a group consistently.
    func commitTabDrag(_ dragged: String, placement: TabDrag.Placement, done: @escaping @MainActor (Bool) -> Void) {
        guard tab(dragged) != nil else { done(false); return }
        let command: Wire.Command
        switch placement {
        case .insert(let target, let after, let outside):
            guard let move = moveCommand(dragged, to: target, after: after, outside: outside) else { done(false); return }
            command = move
        case .intoGroup(let group): command = .init(op: .move, tab: dragged, group: group)
        case .end: command = .init(op: .move, tab: dragged)
        }
        send(command) { result in
            done(result.error == nil)
        }
    }

    /// Resolve an insertion against the current server tree, with the source
    /// removed. Empty source groups remain slots until the server prunes them.
    private func moveCommand(_ dragged: String, to target: String, after: Bool, outside: Bool) -> Wire.Command? {
        guard dragged != target, tab(dragged) != nil, let found = tab(target) else { return nil }
        var idx: Int
        if let group = found.group, !outside {
            var ids = group.tabs.map(\.id)
            ids.removeAll { $0 == dragged }
            guard let at = ids.firstIndex(of: target) else { return nil }
            idx = at
        } else {
            let items = state.items.filter {
                if case .tab(let t) = $0 { return t.id != dragged } else { return true }
            }
            guard let at = items.firstIndex(where: { $0.id == (found.group?.id ?? target) }) else { return nil }
            idx = at
        }
        if after { idx += 1 }
        return .init(op: .move, tab: dragged, group: outside ? nil : found.group?.id, index: idx)
    }

    /// A tab dropped below the list leaves its group for the end of the list.
    func dropAtEnd(_ dragged: String) {
        send(.init(op: .move, tab: dragged))
    }

    /// The attached view for a pane, made on first use.
    func view(for pane: String) -> TerminalView {
        if let v = views[pane] { return v }
        let v = TerminalView(pane: pane, at: endpoint, fontSize: fontSize, controller: controller)
        views[pane] = v
        v.onFocus = { [weak self, weak v] in
            guard let self, let v else { return }
            self.focus(v.paneID)
        }
        v.onConnectionChange = { [weak self, weak v] in
            guard let self else { return }
            if v?.canControl == true { self.createdPanes.remove(pane) }
            self.onViewsChanged?()
        }
        v.attach()
        return v
    }

    /// Existing mirrors only; card-cache pruning must never instantiate a pane.
    var attachedViews: [TerminalView] { Array(views.values) }

    func redrawAll() { views.values.forEach { $0.redraw() } }
    func reloadAppearance() { views.values.forEach { $0.reloadAppearance() } }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        views.values.forEach { $0.fontSize = size }
    }
}
