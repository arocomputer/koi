import AppKit
import Observation
import SwiftUI

/// One read-only sample of an explicitly chosen machine in this client window.
/// Unattached panes stay unattached; sampling never starts a connection or shell.
struct DiagnosticsSnapshot {
    struct Machine: Identifiable { let endpoint: Endpoint; let title: String; var id: Endpoint { endpoint } }
    struct Pane: Identifiable { let id: String; let title: String; let connection: String; let rendering: RenderDiagnosticsSnapshot? }
    struct Issue: Identifiable { let id: String; let date: Date; let subsystem: String; let message: String; let count: Int }
    let machine: Endpoint
    let title: String
    var symbol: String = "desktopcomputer"
    let machines: [Machine]
    let report: Diagnostics
    let server: Wire.Result?
    let checkedAt: Date?
    let refreshError: String?
    let configurationIssues: [String]
    let panes: [Pane]
    let issues: [Issue]
}

/// Observable screen state changes only on user actions or the visible window's
/// one-second sampler, never for each rendered terminal frame.
@MainActor @Observable final class DiagnosticsScreen {
    enum Tab: String, CaseIterable { case overview = "Overview", connections = "Connections", rendering = "Rendering", issues = "Recent Issues" }
    var tab: Tab = .overview
    var snapshot: DiagnosticsSnapshot
    var refreshing = false
    var paused = false
    var filter = ""
    var solid = false
    init(snapshot: DiagnosticsSnapshot) { self.snapshot = snapshot }
}

/// Owns the glass diagnostics window, explicit server probes, and a timer that
/// stops on close/minimize. All providers belong to the invoking app window.
@MainActor final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    let screen: DiagnosticsScreen
    private let sample: (Endpoint) -> DiagnosticsSnapshot
    private let probe: (Endpoint) async -> Void
    private let copy: (Diagnostics) -> Void
    private let export: (Diagnostics) -> Void
    private let openLogs: () -> Void
    private let resetRendering: (Endpoint) -> Void
    private let clearIssues: () -> Void
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var glass: NSVisualEffectView!

    init(machine: Endpoint, sample: @escaping (Endpoint) -> DiagnosticsSnapshot,
         probe: @escaping (Endpoint) async -> Void, copy: @escaping (Diagnostics) -> Void,
         export: @escaping (Diagnostics) -> Void, openLogs: @escaping () -> Void,
         resetRendering: @escaping (Endpoint) -> Void, clearIssues: @escaping () -> Void) {
        self.sample = sample; self.probe = probe; self.copy = copy; self.export = export
        self.openLogs = openLogs; self.resetRendering = resetRendering; self.clearIssues = clearIssues
        screen = DiagnosticsScreen(snapshot: sample(machine))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Koi Diagnostics"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 660, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        glass = NSVisualEffectView()
        let host = NSHostingView(rootView: DiagnosticsView(screen: screen,
            select: { [weak self] in self?.select($0) }, refresh: { [weak self] in self?.refresh() },
            copy: { [weak self] in self?.copyReport() }, export: { [weak self] in self?.exportReport() },
            logs: openLogs, resetRendering: { [weak self] in self?.resetCounters() },
            clearIssues: { [weak self] in self?.clearHistory() }))
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor), host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor), host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        window.contentView = glass
        reloadAppearance()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Use the explicit diagnostics providers") }

    /// Show from a menu action. Offscreen fixtures construct the same window without presenting it.
    func present() {
        update()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startSampling()
    }

    func reloadAppearance() {
        screen.solid = Config.current.solidSurfaces
        window?.appearance = NSAppearance(named: .darkAqua)
        window?.isOpaque = screen.solid
        window?.backgroundColor = screen.solid ? NSColor(Theme.current.backgroundColor) : .clear
        glass.material = screen.solid ? .windowBackground : .hudWindow
        glass.blendingMode = screen.solid ? .withinWindow : .behindWindow
        glass.state = screen.solid ? .inactive : .active
    }

    /// Copy/export the previewed report, including its selected machine and cached-check date.
    func copyReport() { copy(screen.snapshot.report) }
    func exportReport() { export(screen.snapshot.report) }

    func select(_ machine: Endpoint) {
        refreshTask?.cancel(); refreshTask = nil; screen.refreshing = false
        screen.snapshot = sample(machine)
    }

    func update() {
        guard !screen.paused else { return }
        screen.snapshot = sample(screen.snapshot.machine)
    }

    /// Probe only the chosen existing control connection; the provider reports unavailable connections.
    func refresh() {
        guard refreshTask == nil else { return }
        let machine = screen.snapshot.machine, probe = probe
        screen.refreshing = true
        refreshTask = Task { [weak self] in
            await probe(machine)
            guard !Task.isCancelled, let self else { return }
            self.screen.refreshing = false; self.refreshTask = nil
            self.screen.snapshot = self.sample(machine)
        }
    }

    private func resetCounters() { resetRendering(screen.snapshot.machine); screen.snapshot = sample(screen.snapshot.machine) }
    private func clearHistory() { clearIssues(); screen.snapshot = sample(screen.snapshot.machine) }

    private func startSampling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true, self.window?.isMiniaturized == false, !NSApp.isHidden else { return }
                self.update()
            }
        }
        timer?.tolerance = 0.2
    }

    func windowWillMiniaturize(_ notification: Notification) { timer?.invalidate(); timer = nil }
    func windowDidDeminiaturize(_ notification: Notification) { startSampling(); update() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil
        refreshTask?.cancel(); refreshTask = nil; screen.refreshing = false
        window?.nextResponder = nil
    }
    isolated deinit { timer?.invalidate(); refreshTask?.cancel() }
}

/// Four compact diagnostics sections with Koi's shared Capsule selection and
/// floating menus. Reports and errors contain no terminal output or raw log text.
private struct DiagnosticsView: View {
    let screen: DiagnosticsScreen
    let select: (Endpoint) -> Void
    let refresh: () -> Void
    let copy: () -> Void
    let export: () -> Void
    let logs: () -> Void
    let resetRendering: () -> Void
    let clearIssues: () -> Void
    @State private var choosingMachine = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Diagnostics").font(.headline)
                Spacer(minLength: 4)
                Button { choosingMachine.toggle() } label: {
                    Label(screen.snapshot.title, systemImage: screen.snapshot.symbol).lineLimit(1)
                }
                .buttonStyle(.plain)
                .koiPopup(isPresented: $choosingMachine, id: "diagnostics-machine") {
                    PopupMenu(entries: screen.snapshot.machines.map { machine in
                        PopupEntry(title: machine.title, symbol: machine.endpoint == screen.snapshot.machine ? "checkmark" : "", action: { select(machine.endpoint) })
                    })
                }
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(screen.refreshing).help("Refresh server details").accessibilityLabel("Refresh server details")
                Button("Copy Report", action: copy)
                Button("Export…", action: export)
            }
            .buttonStyle(.plain).font(.system(size: 12.5))
            .padding(.leading, 88).padding(.trailing, 18).frame(height: AppDelegate.topRow)
            HStack(spacing: 4) {
                ForEach(DiagnosticsScreen.Tab.allCases, id: \.self) { tab in
                    Button { screen.tab = tab } label: {
                        Text(tab.rawValue).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                            .modifier(SelectionSurface(selected: screen.tab == tab))
                    }.buttonStyle(.plain).accessibilityAddTraits(screen.tab == tab ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Toggle("Pause", isOn: Binding(get: { screen.paused }, set: { screen.paused = $0 }))
                    .toggleStyle(.checkbox).font(.caption).help("Pause automatic display updates")
            }.padding(.horizontal, 18).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch screen.tab {
                    case .overview: overview
                    case .connections: connections
                    case .rendering: rendering
                    case .issues: issues
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(screen.solid ? AnyShapeStyle(Theme.current.backgroundColor) : AnyShapeStyle(.ultraThinMaterial))
            .background(Theme.current.backgroundColor.opacity(0.55))
            .clipShape(.rect(cornerRadius: AppDelegate.paneCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppDelegate.paneCornerRadius).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .padding([.horizontal, .bottom], AppDelegate.inset)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).preferredColorScheme(.dark)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(screen.snapshot.title).font(.title2.weight(.semibold))
            row("App", "\(screen.snapshot.report.appVersion) (\(screen.snapshot.report.appBuild))")
            row("Server", screen.snapshot.server?.serverVersion ?? "Unavailable")
            row("Protocol", "App \(Wire.version) · Server \(screen.snapshot.server?.protocolVersion.map(String.init) ?? "unknown")")
            freshness
            Text("Configuration").font(.headline).padding(.top, 8)
            if screen.snapshot.configurationIssues.isEmpty {
                Label("No configuration issues", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            ForEach(Array(screen.snapshot.configurationIssues.enumerated()), id: \.offset) { _, message in
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            DisclosureGroup("Report preview") {
                Text(screen.snapshot.report.text).font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
            }.padding(.top, 8)
            Button("Open Local Server Log…", action: logs).buttonStyle(.bordered)
        }
    }

    private var freshness: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let date = screen.snapshot.checkedAt {
                Text("Server details checked \(date.formatted(date: .omitted, time: .standard)). Cached until refreshed.")
            } else { Text("Server details have not been checked for this machine.") }
            if let error = screen.snapshot.refreshError { Text(error).foregroundStyle(.orange) }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Control connection", screen.snapshot.report.server.connected ? "Connected" : "Disconnected")
            row("Transport", screen.snapshot.report.server.transport.rawValue)
            if let pid = screen.snapshot.server?.serverPID { row("Server PID", String(pid)) }
            if let uptime = screen.snapshot.server?.uptimeSeconds { row("Server uptime", "\(uptime / 60)m \(uptime % 60)s at last check") }
            freshness
            if let capabilities = screen.snapshot.server?.capabilities {
                row("Capabilities", capabilities.joined(separator: ", "))
            }
            Text("Panes in this window").font(.headline).padding(.top, 8)
            if screen.snapshot.panes.isEmpty { Text("No panes are known for this machine.").foregroundStyle(.secondary) }
            ForEach(screen.snapshot.panes) { pane in
                row(pane.title, pane.connection)
            }
        }
    }

    private var rendering: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Terminal rendering").font(.headline)
                Spacer()
                Button("Reset Counters", action: resetRendering).buttonStyle(.bordered)
            }
            Text("Counters measure this window’s attached terminal renderers. CPU frame work and GPU execution exclude sidebar/tab animation and WindowServer composition.")
                .font(.caption).foregroundStyle(.secondary)
            if screen.snapshot.panes.isEmpty { Text("No renderers to inspect.").foregroundStyle(.secondary) }
            ForEach(screen.snapshot.panes) { pane in
                VStack(alignment: .leading, spacing: 8) {
                    Text(pane.title).font(.headline)
                    if let stats = pane.rendering {
                        row("Metal device", stats.device)
                        row("Drawable", "\(stats.drawableWidth) × \(stats.drawableHeight) px")
                        row("Frames", "\(stats.framesSubmitted) submitted · \(stats.framesCompleted) completed · \(stats.framesFailed) failed")
                        row("Frame waiting", "\(stats.pendingFrame ? "Yes" : "No") · \(stats.inFlight) in flight")
                        row("CPU frame work", timing(stats.lastCPUFrameMS))
                        row("Slowest CPU frame", timing(stats.maxCPUFrameMS))
                        row("GPU execution", timing(stats.lastGPUFrameMS))
                        row("Atlas / vertex buffers", "\(bytes(stats.atlasBytes)) / \(bytes(stats.bufferBytes)) allocated")
                        if stats.deferred.isEmpty { row("Deferred work", "None recorded") }
                        ForEach(stats.deferred.keys.sorted(), id: \.self) { reason in row(deferralTitle(reason), String(stats.deferred[reason] ?? 0)) }
                    } else { Text(pane.connection == "Not attached in this window" ? "Not attached in this window" : "Renderer unavailable").foregroundStyle(.secondary) }
                }.padding(12).background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 10))
            }
        }
    }

    private var issues: some View {
        let entries = screen.snapshot.issues.filter { issue in
            screen.filter.isEmpty || (issue.subsystem + " " + issue.message).localizedCaseInsensitiveContains(screen.filter)
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Filter recent issues", text: Binding(get: { screen.filter }, set: { screen.filter = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button("Clear History", action: clearIssues).buttonStyle(.bordered)
            }
            Text("App issues cover this window’s machines; renderer errors follow the selected machine. Raw logs and terminal contents are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            if entries.isEmpty { Text("No matching issues recorded.").foregroundStyle(.secondary) }
            ForEach(entries) { issue in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(issue.subsystem).fontWeight(.medium)
                        Spacer()
                        Text(issue.date.formatted(date: .omitted, time: .standard))
                        if issue.count > 1 { Text("×\(issue.count)") }
                    }.font(.caption).foregroundStyle(.secondary)
                    Text(issue.message).font(.callout).textSelection(.enabled)
                }.padding(12).background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 8))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout)
    }
    private func timing(_ milliseconds: Double?) -> String { milliseconds.map { String(format: "%.2f ms", $0) } ?? "No sample yet" }
    private func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory) }
    private func deferralTitle(_ reason: String) -> String {
        switch reason {
        case "inflight": "GPU queue busy"
        case "noDrawable": "Drawable unavailable"
        case "zeroSize": "Waiting for drawable size"
        case "buffer": "Vertex buffer unavailable"
        case "commandBuffer": "Command buffer unavailable"
        case "encoder": "Render encoder unavailable"
        default: reason
        }
    }
}
