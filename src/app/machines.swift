import AppKit
import SwiftUI
import Observation

/// The machines whose tabs Koi shows: this Mac, and the ones the user added
/// by their SSH name. Each machine has its own workspace, so switching is
/// instant once connected and every machine's tabs stay current.
@MainActor @Observable
final class Machines {
    enum Status: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    private(set) var hosts: [String]
    private(set) var current: Endpoint = .local
    private(set) var status: [String: Status] = [:]
    let deviceIcons = DeviceIcons.shared

    /// Called with the tab to show when the shown machine or what its
    /// selected tab shows changes.
    @ObservationIgnored var onShow: ((Wire.TabInfo?) -> Void)?
    @ObservationIgnored var onViewsChanged: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored var onEmpty: (() -> Void)?
    /// Refresh server facts after a workspace establishes its control connection.
    @ObservationIgnored var onServerConnected: ((Endpoint) -> Void)?
    @ObservationIgnored private var workspaces: [Endpoint: Workspace] = [:]
    @ObservationIgnored private var preparations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var preparationGeneration: [String: UUID] = [:]

    init() {
        hosts = Layout.load().hosts
    }

    isolated deinit { preparations.values.forEach { $0.cancel() } }

    /// The shown machine's workspace.
    var workspace: Workspace { workspace(for: current) }

    var allWorkspaces: [Workspace] { Array(workspaces.values) }

    /// Shows this Mac (or the machine shown last time) and connects to every
    /// added machine in the background, so switching to one is instant and
    /// its tabs are already current.
    func start() {
        deviceIcons.probe(.local)
        _ = workspace(for: .local)
        let saved = Layout.load().current
        for host in hosts where host != saved { connect(.ssh(host)) }
        if let saved, hosts.contains(saved) { select(.ssh(saved)) }
    }

    /// Shows a machine: at once if connected, else once Koi there is ready.
    func select(_ endpoint: Endpoint) {
        guard case .ssh(let host) = endpoint, status[host] != .ready else {
            show(endpoint)
            return
        }
        pendingShow = endpoint
        connect(endpoint)
    }

    /// The machine to show once its connection is ready.
    @ObservationIgnored private var pendingShow: Endpoint?

    /// Installs Koi on the machine if needed and opens the link to it, in
    /// the background; shows it afterwards if it was selected meanwhile.
    private func connect(_ endpoint: Endpoint) {
        guard case .ssh(let host) = endpoint, hosts.contains(host), status[host] != .connecting, status[host] != .ready else { return }
        status[host] = .connecting
        let generation = UUID()
        preparationGeneration[host] = generation
        preparations[host] = Task.detached { [weak self] in
            guard !Task.isCancelled else { return }
            let failure: String?
            do {
                try Remote.prepare(host)
                failure = nil
            } catch {
                failure = "\(error)"
            }
            await MainActor.run {
                guard let self, self.hosts.contains(host), self.preparationGeneration[host] == generation else { return }
                self.preparations[host] = nil
                self.preparationGeneration[host] = nil
                if let failure {
                    self.status[host] = .failed(failure)
                } else {
                    self.status[host] = .ready
                    _ = self.workspace(for: endpoint)
                    if self.pendingShow == endpoint {
                        self.pendingShow = nil
                        self.show(endpoint)
                    }
                }
            }
        }
    }

    /// Adds a machine by its SSH name and shows it.
    func add(_ host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if !hosts.contains(host) {
            hosts.append(host)
            saveLayout()
        }
        select(.ssh(host))
    }

    func remove(_ host: String) {
        deviceIcons.remove(.ssh(host))
        preparations.removeValue(forKey: host)?.cancel()
        preparationGeneration[host] = nil
        if pendingShow == .ssh(host) { pendingShow = nil }
        hosts.removeAll { $0 == host }
        status[host] = nil
        if let w = workspaces.removeValue(forKey: .ssh(host)) { w.detachAll() }
        onViewsChanged?()
        if current == .ssh(host) { show(.local) }
        saveLayout()
    }

    private func show(_ endpoint: Endpoint) {
        current = endpoint
        saveLayout()
        onShow?(workspace(for: endpoint).tab(workspace(for: endpoint).selectedTab)?.tab)
    }

    private func workspace(for endpoint: Endpoint) -> Workspace {
        if let w = workspaces[endpoint] { return w }
        let w = Workspace(endpoint)
        workspaces[endpoint] = w
        w.onShow = { [weak self] tab in
            guard let self, self.current == endpoint else { return }
            self.onShow?(tab)
        }
        w.onEmpty = { [weak self] in self?.emptied(endpoint) }
        w.onViewsChanged = { [weak self] in self?.onViewsChanged?() }
        w.onError = { [weak self] in self?.onError?($0) }
        w.onConnected = { [weak self] in
            self?.deviceIcons.probe(endpoint)
            self?.onServerConnected?(endpoint)
        }
        w.start()
        return w
    }

    /// Empty background workspaces retire without closing a different machine.
    /// An empty visible local workspace closes only its owning client window.
    private func emptied(_ endpoint: Endpoint) {
        switch endpoint {
        case .local:
            workspaces.removeValue(forKey: .local)?.detachAll()
            onViewsChanged?()
            if current == .local { onEmpty?() }
        case .ssh(let host):
            workspaces[endpoint] = nil
            onViewsChanged?()
            status[host] = nil
            if current == endpoint { show(.local) }
        }
    }

    private func saveLayout() {
        var layout = Layout.load()
        layout.hosts = hosts
        if case .ssh(let host) = current { layout.current = host } else { layout.current = nil }
        layout.save()
    }
}

/// A compact replacement for the two-line machine pill, opening the same picker.
struct MachineButton: View {
    let machines: Machines
    @State private var presented = false

    private var title: String {
        let name = machines.current == .local ? "This Mac (" + (Host.current().localizedName ?? "local") + ")" : machines.current.title
        return "Machines — " + name
    }

    var body: some View {
        TopRowButton(help: title, action: { presented.toggle() }) {
            Image(systemName: machines.deviceIcons.symbol(for: machines.current)).font(.system(size: 15))
        }
        .koiPopup(isPresented: $presented, id: "machines") {
            MachineList(machines: machines) { presented = false }
        }
    }
}

extension Endpoint {
    var title: String {
        switch self {
        case .local: "This Mac"
        case .ssh(let host): host
        }
    }

}

/// The machines Koi knows: this Mac and the ones you added, each with how
/// its connection is doing, then a way to add another from your SSH hosts.
private struct MachineList: View {
    let machines: Machines
    let dismiss: () -> Void
    @State private var adding: Bool
    @State private var host = ""
    @State private var selected: Int?
    @FocusState private var listFocused: Bool
    @FocusState private var hostFocused: Bool

    init(machines: Machines, dismiss: @escaping () -> Void) {
        self.machines = machines
        self.dismiss = dismiss
        _adding = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if adding {
                addForm
            } else {
                MachineRow(endpoint: .local, machines: machines, highlighted: selected == 0,
                           select: { select(.local) })
                    .onHover { if $0 { selected = 0 } }
                ForEach(Array(machines.hosts.enumerated()), id: \.element) { index, host in
                    MachineRow(endpoint: .ssh(host), machines: machines, highlighted: selected == index + 1,
                               select: { select(.ssh(host)) })
                        .onHover { if $0 { selected = index + 1 } }
                }
                Divider().padding(.vertical, 3)
                ListButton(symbol: "plus", title: "Add Machine…", highlighted: selected == machines.hosts.count + 1) {
                    adding = true
                }
                .onHover { if $0 { selected = machines.hosts.count + 1 } }
            }
        }
        .font(.system(size: 14))
        .padding(6)
        .frame(width: 260)
        .focusable(!adding)
        .focusEffectDisabled()
        .focused($listFocused)
        .onAppear { listFocused = !adding; hostFocused = adding }
        .onChange(of: adding) { _, adding in
            listFocused = !adding
            hostFocused = adding
        }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            guard !adding, let selected else { return .ignored }
            let endpoints: [Endpoint] = [.local] + machines.hosts.map { .ssh($0) }
            if selected < endpoints.count { select(endpoints[selected]) } else { adding = true }
            return .handled
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard !adding else { return .ignored }
        let count = machines.hosts.count + 2
        selected = ((selected ?? (offset > 0 ? -1 : 0)) + offset + count) % count
        return .handled
    }

    /// Dismiss before a ready machine switches so focus follows its terminal.
    /// A machine still connecting keeps its progress and retry UI visible.
    private func select(_ endpoint: Endpoint) {
        if case .ssh(let host) = endpoint, machines.status[host] != .ready {
            machines.select(endpoint)
            return
        }
        dismiss()
        machines.select(endpoint)
    }

    private var addForm: some View {
        let known = Remote.configuredHosts().filter { !machines.hosts.contains($0) }
        return VStack(alignment: .leading, spacing: 1) {
            Text("Add a machine you reach with SSH")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            ForEach(known, id: \.self) { h in
                ListButton(symbol: "desktopcomputer", title: h) { add(h) }
            }
            HStack(spacing: 6) {
                TextField("user@host", text: $host)
                    .textFieldStyle(.plain)
                    .focused($hostFocused)
                    .onSubmit { add(host) }
                Button("Add") { add(host) }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7, style: .continuous))
            .padding(.top, 4)
        }
    }

    private func add(_ h: String) {
        machines.add(h)
        adding = false
        host = ""
    }
}

private struct MachineRow: View {
    let endpoint: Endpoint
    let machines: Machines
    let highlighted: Bool
    let select: () -> Void

    var body: some View {
        let failure: String? = if case .ssh(let h) = endpoint, case .failed(let m) = machines.status[h] { m } else { nil }
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 9) {
                    Image(systemName: machines.deviceIcons.symbol(for: endpoint)).frame(width: 18)
                    Text(endpoint.title).lineLimit(1)
                    Spacer()
                    if case .ssh(let h) = endpoint, machines.status[h] == .connecting {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else if failure != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if machines.current == endpoint {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    }
                }
                if let failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 27)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(Color.primary.opacity(highlighted ? 0.09 : machines.current == endpoint ? 0.05 : 0), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .koiContextMenu("machine", removalActions)
    }

    private var removalActions: [PopupEntry] {
        guard case .ssh(let host) = endpoint else { return [] }
        return [.init(title: "Remove Machine", symbol: "trash", destructive: true,
                      action: { machines.remove(host) })]
    }
}

/// A row in a floating list that acts when clicked.
private struct ListButton: View {
    let symbol: String
    let title: String
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(Color.primary.opacity(hovering || highlighted ? 0.09 : 0), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Live machine profiles embedded in Settings' glass content pane. The owner
/// supplies server probes and diagnostic actions; drafts never change a machine.
struct MachineSettingsView: View {
    let machines: Machines
    let inspector: ServerInspector
    let refresh: (Endpoint) -> Void
    let copyDiagnostics: (Endpoint) -> Void
    let openLogs: () -> Void

    @State private var profile: Endpoint?
    @State private var newHost = ""
    @State private var editingHost: String?
    @State private var editedHost = ""

    private var endpoint: Endpoint { profile ?? machines.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Machines").font(.title3.weight(.semibold))
                machine(.local)
                ForEach(machines.hosts, id: \.self) { host in machine(.ssh(host)) }
            }
            addForm
            Divider().opacity(0.35)
            details
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refresh(endpoint) }
        .onChange(of: endpoint) { _, endpoint in refresh(endpoint) }
        .onChange(of: machines.hosts) { _, hosts in
            if case .ssh(let host) = profile, !hosts.contains(host) { profile = nil }
            if let editingHost, !hosts.contains(editingHost) { self.editingHost = nil }
        }
    }

    /// Inspecting a profile is read-only; switching and setup retry are explicit.
    private func machine(_ machine: Endpoint) -> some View {
        HStack(spacing: 10) {
            Button { profile = machine } label: {
                HStack(spacing: 10) {
                    Image(systemName: machines.deviceIcons.symbol(for: machine)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(machine.title).font(.body.weight(.medium))
                        Text(status(for: machine)).font(.caption).foregroundStyle(.secondary)
                        if case .ssh(let host) = machine, case .failed(let error) = machines.status[host] {
                            Text(error).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if machines.current == machine {
                        Label("Current", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect \(machine.title), \(status(for: machine))")
            .accessibilityAddTraits(endpoint == machine ? .isSelected : [])
            if case .ssh(let host) = machine, machines.status[host] == .connecting {
                ProgressView().controlSize(.small).accessibilityLabel("Setting up \(host)")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(endpoint == machine ? 0.09 : 0.04),
                    in: .rect(cornerRadius: 10, style: .continuous))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add an SSH machine").font(.headline)
            Text("Use an SSH alias or user@host. Configure ports, keys and jump hosts in ~/.ssh/config.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                hostField("SSH alias or user@host", text: $newHost)
                action("Add", symbol: "plus", label: "Add SSH machine") {
                    guard hostError(newHost) == nil else { return }
                    let host = newHost
                    newHost = ""
                    profile = .ssh(host)
                    machines.add(host)
                }
                .disabled(hostError(newHost) != nil)
            }
            if !newHost.isEmpty, let error = hostError(newHost) { feedback(error) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(endpoint.title).font(.title3.weight(.semibold))
                Spacer()
                action("Refresh", symbol: "arrow.clockwise", label: "Refresh \(endpoint.title) server details") {
                    refresh(endpoint)
                }
            }
            Text(status(for: endpoint)).font(.callout).foregroundStyle(.secondary)
            if case .ssh(let host) = endpoint, case .failed(let error) = machines.status[host] {
                feedback(error)
            }
            HStack(spacing: 8) {
                if case .ssh(let host) = endpoint, case .failed = machines.status[host] {
                    action("Retry", symbol: "arrow.clockwise", label: "Retry SSH setup for \(host)") {
                        machines.select(endpoint)
                    }
                } else if machines.current != endpoint {
                    action("Switch to Machine", symbol: "arrow.right", label: "Switch to \(endpoint.title)") {
                        machines.select(endpoint)
                    }
                }
                if case .ssh(let host) = endpoint {
                    action("Edit Alias", symbol: "pencil", label: "Edit SSH alias for \(host)") {
                        editingHost = host
                        editedHost = host
                    }
                    action("Remove", symbol: "minus.circle", label: "Remove \(host) and leave its jobs running") {
                        profile = nil
                        editingHost = nil
                        machines.remove(host)
                    }
                }
            }
            if case .ssh(let host) = endpoint {
                if editingHost == host { editForm(host) }
                Text("Removing a machine detaches this client. Its server and jobs keep running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            serverDetails
            if endpoint == machines.current { paneConnections }
            HStack(spacing: 8) {
                action("Copy Diagnostics", symbol: "doc.on.doc", label: "Copy diagnostics") { copyDiagnostics(endpoint) }
                if endpoint == .local {
                    action("Open Server Log", symbol: "doc.text", label: "Open local server log", perform: openLogs)
                }
            }
            if endpoint != .local {
                Text("Remote server logs are unavailable here. Inspect them on the remote machine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Keep the old profile and setup status until the user clicks Save Alias.
    private func editForm(_ host: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            hostField("Replacement SSH alias or user@host", text: $editedHost)
            Text("Saving replaces this entry and connects to the new address. Existing remote jobs keep running.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                action("Save Alias", symbol: "checkmark", label: "Save replacement SSH alias for \(host)") {
                    guard editedHost != host, hostError(editedHost, replacing: host) == nil else { return }
                    let replacement = editedHost
                    editingHost = nil
                    machines.remove(host)
                    profile = .ssh(replacement)
                    machines.add(replacement)
                }
                .disabled(editedHost == host || hostError(editedHost, replacing: host) != nil)
                action("Cancel", symbol: "xmark", label: "Cancel alias edit") { editingHost = nil }
            }
            if let error = hostError(editedHost, replacing: host) { feedback(error) }
        }
    }

    @ViewBuilder private var serverDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server").font(.headline)
            Text(inspector.summary(for: endpoint)).font(.callout).foregroundStyle(.secondary)
            if let error = inspector.errors[endpoint] {
                feedback(error)
            } else if let reply = inspector.replies[endpoint], reply.error == nil {
                fact("Version", reply.serverVersion ?? "Not reported")
                fact("PID", reply.serverPID.map { String($0) } ?? "Not reported")
                fact("Protocol", reply.protocolVersion.map { String($0) } ?? "Not reported")
                fact("Uptime", reply.uptimeSeconds.map { "\($0) seconds" } ?? "Not reported")
                let capabilities = reply.capabilities?.filter { inspector.supports($0, at: endpoint) }.sorted()
                fact("Capabilities", capabilities.map { $0.isEmpty ? "None reported" : $0.joined(separator: ", ") } ?? "Not reported")
            }
        }
        .textSelection(.enabled)
    }

    /// Read existing pane mirrors only. Advertised transports do not identify
    /// the route any pane is actually using, and inspecting must not attach panes.
    private var paneConnections: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pane connections").font(.headline)
            let views = machines.allWorkspaces.first { $0.endpoint == endpoint }?.attachedViews ?? []
            if views.isEmpty {
                Text("No attached panes.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(views.sorted { $0.paneID < $1.paneID }, id: \.paneID) { view in
                    fact("Pane \(view.paneID)", view.connectionDescription)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// SSH setup readiness is distinct from a live pane connection.
    private func status(for endpoint: Endpoint) -> String {
        guard case .ssh(let host) = endpoint else {
            let views = machines.allWorkspaces.first { $0.endpoint == .local }?.attachedViews ?? []
            let descriptions = Set(views.map(\.connectionDescription)).sorted()
            return descriptions.isEmpty ? "No attached panes" : descriptions.joined(separator: " · ")
        }
        switch machines.status[host] {
        case .connecting: return "Setting up SSH…"
        case .ready: return "SSH setup ready"
        case .failed: return "SSH setup failed"
        case nil: return "SSH setup not started"
        }
    }

    /// Accept one destination, never SSH options, whitespace or shell syntax.
    private func hostError(_ host: String, replacing original: String? = nil) -> String? {
        guard !host.isEmpty else { return "Enter an SSH alias or user@host." }
        guard !host.contains(where: \.isWhitespace),
              host.range(of: #"\A(?:[A-Za-z0-9_][A-Za-z0-9_.+-]*@)?[A-Za-z0-9_][A-Za-z0-9_.:-]*\z"#,
                         options: .regularExpression) != nil else {
            return "Use an SSH alias or user@host without options or whitespace."
        }
        if host != original, machines.hosts.contains(host) { return "This SSH machine is already saved." }
        return nil
    }

    private func hostField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain).padding(9)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7))
            .accessibilityLabel(title)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feedback(_ message: String) -> some View {
        Text(message).font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    /// Text and glyph stay inside the same accessible, plainly styled hit target.
    private func action(_ title: String, symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}


