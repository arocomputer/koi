import AppKit
import SwiftUI
import QuartzCore
import UserNotifications

/// How long the app took to show its first local pane, the one startup
/// number worth watching: it covers the window, the server connection and
/// the first snapshot. Logged once and reported in Diagnostics.
@MainActor enum Launch {
    static var started = CACurrentMediaTime()
    private(set) static var firstPaneMilliseconds: Int?

    static func noteFirstPane() {
        guard firstPaneMilliseconds == nil else { return }
        let ms = Int((CACurrentMediaTime() - started) * 1000)
        firstPaneMilliseconds = ms
        FileHandle.standardError.write(Data("[koi] first pane ready \(ms) ms after launch\n".utf8))
    }
}

/// A glass terminal window and its independent selection, connections and chrome.
/// The application delegate retains additional window owners until they close.
///
/// Quitting or closing the window only detaches: every shell keeps running
/// in the server, and the next launch shows them again. A tab ends when its
/// shell exits or you close it.
@MainActor
final class AppDelegate: NSResponder, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    weak var applicationOwner: AppDelegate?
    private var additionalWindows: [AppDelegate] = []
    private var windowClosed = false
    private var accessibilityObserver: NSObjectProtocol?
    let serverInspector = ServerInspector()
    private let activityCenter = ActivityCenter()
    /// Created only where used: the application owner's.
    private lazy var appUpdater = AppUpdater()
    private var projectStore: ProjectStore?
    private var probingServers: Set<Endpoint> = []
    private var configuredPanes: [Endpoint: [String: Wire.Appearance]] = [:]
    private var projectRestoreTask: Task<Void, Never>?
    private let diagnosticIssues = DiagnosticIssues()
    private var diagnosticsWindow: DiagnosticsWindowController?
    private var paneConnectionStates: [ObjectIdentifier: String] = [:]
    var window: NSWindow!
    var card: SplitContainerView!
    var chromeLayout: ChromeLayout!
    var sidebarView: NSView!
    var topBarView: NSView!
    var topBarLeading: NSLayoutConstraint!
    var newTabButton: NSView!
    var toggleButton: NSHostingView<AnyView>!
    var resizeHandle: SidebarResizeHandle!
    var sidebarResize: (width: CGFloat, tabs: Config.Tabs, hold: UUID)?
    var preferredSidebarWidth: CGFloat = {
        let width = UserDefaults.standard.double(forKey: "sidebarWidth")
        return width.isFinite && width > 0 ? CGFloat(width) : AppDelegate.sidebarWidth
    }()
    let machines = Machines()
    private let palettePresenter = PopupAnchor.Coordinator()
    /// The shown machine's workspace.
    var workspace: Workspace { machines.workspace }
    var fontSize: CGFloat = 13
    var sidebarShown = true
    var sidebarProgress: CGFloat = 1
    var sidebarMotion: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?
    var sidebarDisplayLink: CADisplayLink?
    var sidebarTransition: UUID?
    var sidebarTransitionHold: UUID?
    var installedTabs: Config.Tabs?
    /// The workspace whose intents the pane cards carry; actions are rebuilt
    /// only when the machine, and so the workspace, changes.
    var actionsOwner: ObjectIdentifier?
    private var paneEscapeMonitor: Any?

    var coveredChrome: [ChromeCoverage] = []

    isolated deinit {
        sidebarDisplayLink?.invalidate()
        coveredChrome.forEach { $0.restore() }
    }

    /// The initial rail width; a drag shares its saved width between vertical edges.
    static let sidebarWidth: CGFloat = 248
    static let inset: CGFloat = 5
    /// The window's corner radius: 26 pt on macOS 26, or what the global
    /// `NSConvolutionOverride1` default sets it to. Cards inside it curve
    /// concentrically, their radius this less the inset.
    static let windowCornerRadius: CGFloat = {
        let override = UserDefaults.standard.double(forKey: "NSConvolutionOverride1")
        return override > 0 ? override : 26
    }()
    /// The pane cards' corner radius. Tuned by eye rather than held strictly
    /// concentric with the window, which read a touch too round.
    static let paneCornerRadius: CGFloat = 17
    /// The window header row. SidebarView reserves this height; AppDelegate
    /// owns its vertical controls and AppKit owns the native traffic lights.
    static let topRow: CGFloat = 52

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.writeStarterIfMissing()
        Config.current = Config.load()
        Self.installMenu()
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.global(qos: .utility).async { LocalServer.readBundledVersion() }
        launchWindow()
        appUpdater.start()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applyConfig() } }
    }

    /// New windows attach independently to the same persistent sessions.
    /// Closing a client window never closes its server's processes.
    func launchWindow(present: Bool = true) {
        fontSize = Config.current.fontSize
        window = makeWindow()
        nextResponder = NSApp
        machines.onShow = { [weak self] in self?.show($0) }
        machines.onViewsChanged = { [weak self] in self?.workspaceStateChanged() }
        machines.onError = { [weak self] in self?.showError($0, subsystem: "Connection") }
        machines.onEmpty = { [weak self] in self?.window.performClose(nil) }
        machines.onServerConnected = { [weak self] endpoint in
            self?.serverInspector.invalidate(endpoint)
            self?.configuredPanes[endpoint] = nil
            self?.workspaceStateChanged()
        }
        paneEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, event.window === self.window,
                  self.card.isDraggingPane else { return event }
            self.card.cancelPaneDrag(untilRelease: true)
            return nil
        }
        #if KOID
        if present { Dev.configure(window) { [weak self] request in self?.previewPalette(request) } }
        #else
        if present { window.makeKeyAndOrderFront(nil); NSApp.activate() }
        #endif
        machines.start()
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = newWindowOwner()
        controller.window.setFrameOrigin(NSPoint(x: window.frame.minX + 24, y: window.frame.minY - 24))
        controller.window.makeKeyAndOrderFront(nil)
    }

    /// Retain a client before it connects; offscreen callers use the same lifecycle.
    @discardableResult func newWindowOwner(present: Bool = true) -> AppDelegate {
        let owner = applicationOwner ?? self
        let controller = AppDelegate()
        controller.applicationOwner = owner
        owner.additionalWindows.append(controller)
        controller.launchWindow(present: present)
        return controller
    }

    var windowOwners: [AppDelegate] {
        let owner = applicationOwner ?? self
        return ([owner] + owner.additionalWindows).filter { !$0.windowClosed }
    }

    /// Cancel a window's UI work and detach only its own client connections.
    func closeWindowOwner() {
        guard !windowClosed else { return }
        windowClosed = true
        projectRestoreTask?.cancel()
        projectRestoreTask = nil
        palettePresenter.dismiss()
        diagnosticsWindow?.close()
        diagnosticsWindow = nil
        cleanupWindow()
        if window?.nextResponder === self { window.nextResponder = nil }
        nextResponder = nil
        if let paneEscapeMonitor { NSEvent.removeMonitor(paneEscapeMonitor) }
        paneEscapeMonitor = nil
        machines.allWorkspaces.forEach { $0.detachAll() }
        // The application delegate can outlive its first closed window. Drop
        // that window's terminal buffers while retaining safe window identity.
        if let source = machines.allWorkspaces.first {
            card?.show(nil, focused: nil, zoomed: nil, view: source.view(for:))
        }
        card?.prunePaneCards(keeping: [])
        card?.actions = nil
        if let owner = applicationOwner {
            DispatchQueue.main.async { [self, weak owner] in
                owner?.additionalWindows.removeAll { $0 === self }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        (additionalWindows + [self]).forEach { $0.closeWindowOwner() }
        additionalWindows.removeAll()
        Layout.flush()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
    }

    // MARK: Actions

    @objc func newTab(_ sender: Any?) { workspace.newTab() }
    @objc func closeTab(_ sender: Any?) {
        if closeKeyAuxiliaryWindow() { return }
        workspace.closeTab()
    }
    @objc func splitRight(_ sender: Any?) { workspace.splitPane(.right) }
    @objc func splitDown(_ sender: Any?) { workspace.splitPane(.down) }
    @objc func closePane(_ sender: Any?) {
        if closeKeyAuxiliaryWindow() { return }
        workspace.closePane()
    }

    /// If a window other than the main one is key (the Settings window), ⌘W
    /// closes it rather than a pane, and never quits Koi.
    private func closeKeyAuxiliaryWindow() -> Bool {
        guard let key = NSApp.keyWindow, key !== window else { return false }
        key.performClose(nil)
        return true
    }
    /// Paste lands here when the responder chain misses the terminal: a
    /// launcher such as Raycast pastes with a synthetic ⌘V the moment its
    /// panel closes, which can be before the window has the keyboard back.
    /// The selected pane takes it.
    @objc func paste(_ sender: Any?) { workspace.selectedView?.paste(sender) }
    @objc func zoomPane(_ sender: Any?) { workspace.toggleZoom() }
    @objc func nextPane(_ sender: Any?) { workspace.focusPane(offset: 1) }
    @objc func previousPane(_ sender: Any?) { workspace.focusPane(offset: -1) }
    @objc func focusLeft(_ sender: Any?) { focus(.left) }
    @objc func focusRight(_ sender: Any?) { focus(.right) }
    @objc func focusUp(_ sender: Any?) { focus(.up) }
    @objc func focusDown(_ sender: Any?) { focus(.down) }

    private func focus(_ direction: SplitContainerView.Direction) {
        guard let from = workspace.focusedPane, let to = card.pane(from: from, toward: direction) else { return }
        workspace.focus(to)
    }
    @objc func nextTab(_ sender: Any?) { workspace.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { workspace.selectTab(offset: -1) }
    @objc func selectNumberedTab(_ sender: NSMenuItem) { workspace.selectTab(number: sender.tag) }

    /// Route the sidebar action to the window's geometry and motion owner.
    @objc func toggleKoiSidebar(_ sender: Any?) { toggleSidebar() }

    /// Disable sidebar collapse in Top placement and fullscreen while Settings is key.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFullScreen(_:)), NSApp.keyWindow is SettingsWindow { return false }
        return menuItem.action != #selector(toggleKoiSidebar(_:)) || Config.current.tabs.isVertical
    }

    /// A clean, one-time toast in the bottom-right corner: the first time the
    /// sidebar hides, it names the shortcut that brings it back, then never
    /// shows again.
    func showSidebarHint() {
        let key = "sawSidebarHint"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        toast("Press ⌘S to show the sidebar")
    }

    /// Show a transient notice in the current window.
    private func toast(_ text: String) {
        guard !windowClosed, let parent = window?.contentView else { return }
        Toast.show(text, in: parent)
    }

    /// Record an actual user-visible failure, without adding successful notices to history.
    private func showError(_ message: String, subsystem: String = "Application", in target: NSWindow? = nil) {
        diagnosticIssues.record(subsystem: subsystem, message: message, sensitiveHosts: machines.hosts)
        if let parent = target?.contentView { Toast.show(message, in: parent) }
        else { toast(message) }
    }

    /// Route failed persistence to the initiating UI, and refresh every window.
    private func savePreference(_ key: String, _ value: String) throws {
        try Config.set(key, value)
        applyConfig()
        if key.hasPrefix("notify-"), value == "true" {
            Task { await (applicationOwner ?? self).activityCenter.requestAuthorizationFromUserAction() }
        }
    }

    private func changePreference(_ key: String, _ value: String) {
        do { try savePreference(key, value) }
        catch { showError(error.localizedDescription) }
    }

    /// State changes feed activity once per application and configure new panes
    /// only once per terminal-default change, avoiding command/state notification loops.
    private func workspaceStateChanged() {
        guard !windowClosed else { return }
        prunePaneCards()
        let attached = machines.allWorkspaces.flatMap(\.attachedViews)
        let live = Set(attached.map(ObjectIdentifier.init))
        paneConnectionStates = paneConnectionStates.filter { live.contains($0.key) }
        for view in attached {
            let key = ObjectIdentifier(view), state = view.connectionDescription
            if paneConnectionStates[key] == nil, !view.rendererAvailable {
                diagnosticIssues.record(subsystem: "Rendering", message: "Renderer unavailable for pane \(view.paneID).")
            }
            if paneConnectionStates[key] != state,
               state.hasPrefix("Connection lost") || state.hasPrefix("Connection error") {
                diagnosticIssues.record(subsystem: "Pane connection", message: "Pane \(view.paneID): \(state)", sensitiveHosts: machines.hosts)
            }
            paneConnectionStates[key] = state
        }
        let owner = applicationOwner ?? self
        var sources: [Endpoint: Workspace] = [:]
        for controller in [owner] + owner.additionalWindows where !controller.windowClosed {
            for source in controller.machines.allWorkspaces {
                // A second window may receive the same broadcast later. Keep one
                // connected source so stale duplicates cannot replay activity alerts.
                if sources[source.endpoint] == nil || sources[source.endpoint]?.transport == .disconnected {
                    sources[source.endpoint] = source
                }
            }
        }
        let snapshot = sources.mapValues(\.state)
        Task { await owner.activityCenter.consume(snapshot: snapshot) }
        for source in machines.allWorkspaces where !source.state.tabs.isEmpty {
            guard !probingServers.contains(source.endpoint) else { continue }
            let endpoint = source.endpoint
            probingServers.insert(endpoint)
            Task { [weak self, weak source] in
                guard let self, let source else { return }
                defer { self.probingServers.remove(endpoint) }
                if !self.serverInspector.attempted.contains(endpoint) {
                    await self.serverInspector.refresh(endpoint) { try await source.perform($0, reportingErrors: false) }
                    source.serverCapabilities = Set(self.serverInspector.replies[endpoint]?.capabilities ?? [])
                }
                guard self.serverInspector.supports("configurePane", at: endpoint) else { return }
                let appearance = ServerInspector.appearance
                for pane in source.state.tabs.flatMap(\.panes) {
                    // Observing another client's work must not reconfigure its
                    // engine or broadcast replacement snapshots to that client.
                    if endpoint != .local, !source.attachedViews.contains(where: { $0.paneID == pane.id && $0.canControl }) { continue }
                    if self.configuredPanes[endpoint]?[pane.id] == appearance { continue }
                    self.configuredPanes[endpoint, default: [:]][pane.id] = appearance
                    do { _ = try await source.perform(.init(op: .configurePane, pane: pane.id, appearance: appearance), reportingErrors: false) }
                    catch { self.configuredPanes[endpoint]?[pane.id] = nil; self.showError(error.localizedDescription); break }
                }
            }
        }
    }

    /// Reloads config and applies fonts, layout, and shortcuts
    /// without restarting the app or its shells.
    private func applyConfig() {
        Config.current = Config.load()
        let owner = applicationOwner ?? self
        for controller in [owner] + owner.additionalWindows where !controller.windowClosed {
            controller.setFontSize(Config.current.fontSize)
            controller.machines.allWorkspaces.forEach { $0.reloadAppearance() }
            controller.installChrome()
            controller.applyWindowAppearance()
            controller.applySettingsAppearance()
            controller.diagnosticsWindow?.reloadAppearance()
            controller.configuredPanes.removeAll()
            controller.workspaceStateChanged()
        }
        Self.installMenu()
        NotificationCenter.default.post(name: Config.didReload, object: nil)
    }

    @objc func reloadConfig(_ sender: Any?) {
        let before = Config.current
        applyConfig()
        toast(before != Config.current ? "Config reloaded" : "Config unchanged")
    }

    /// Opens the Settings window: tabs across the top, controls below,
    /// writing through to the config file and applying at once.
    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let view = SettingsView(
                apply: { [weak self] key, value in try self?.savePreference(key, value) },
                rebind: { [weak self] action, bind in try Config.setKeybind(action, bind); self?.applyConfig() },
                reset: { [weak self] key in try Config.reset(key: key); self?.applyConfig() },
                resetKeybind: { [weak self] action in try Config.resetKeybind(action); self?.applyConfig() },
                openConfigFile: { Config.writeStarterIfMissing(); NSWorkspace.shared.open(Paths.config) },
                machines: { [weak self] in self.map { AnyView($0.machineSettings) } ?? AnyView(EmptyView()) },
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                openLogs: { NSWorkspace.shared.open(Paths.serverLog) },
                copyDiagnostics: { [weak self] in if let self { Self.copyText(self.diagnostics.text) } },
                checkForUpdates: { [weak self] in self?.checkUpdates(nil) },
                installCLI: { try Self.installCLI() },
                activityContent: { [weak self] in self.map { AnyView(ActivitySettingsView(center: ($0.applicationOwner ?? $0).activityCenter)) } ?? AnyView(EmptyView()) },
                advancedContent: { [weak self] in
                    guard let self else { return AnyView(EmptyView()) }
                    return AnyView(VStack(alignment: .leading, spacing: 24) {
                        UpdateSettingsView(updater: (applicationOwner ?? self).appUpdater)
                        IntegrationSettingsView()
                    })
                },
                exportDiagnostics: { [weak self] in self?.exportDiagnostics(nil) })
            let w = SettingsWindow()
            w.title = "Koi Settings"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            // The same desktop-blur glass the main window floats on.
            let glass = NSVisualEffectView()
            glass.material = .sidebar
            glass.blendingMode = .behindWindow
            glass.state = .active
            let host = NSHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.safeAreaRegions = []
            glass.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: glass.topAnchor),
                host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            w.contentView = glass
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(type)?.isHidden = true
            }
            w.isMovableByWindowBackground = true
            settingsWindow = w
        }
        settingsWindow?.center()
        applySettingsAppearance()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Opens the config file in the user's editor, making it first if needed.
    @objc func openConfig(_ sender: Any?) {
        Config.writeStarterIfMissing()
        NSWorkspace.shared.open(Paths.config)
    }

    private var settingsWindow: NSWindow?

    private func applySettingsAppearance() {
        guard let settingsWindow else { return }
        settingsWindow.appearance = NSAppearance(named: .darkAqua)
        let solid = Config.current.solidSurfaces
        settingsWindow.isOpaque = solid
        settingsWindow.backgroundColor = solid ? NSColor(Theme.current.backgroundColor) : .clear
        if let glass = settingsWindow.contentView as? NSVisualEffectView {
            glass.material = solid ? .windowBackground : .sidebar
            glass.blendingMode = solid ? .withinWindow : .behindWindow
            glass.state = solid ? .inactive : .active
        }
    }

    @objc func biggerText(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func smallerText(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func actualSizeText(_ sender: Any?) { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, 6), 72)
        machines.allWorkspaces.forEach { $0.setFontSize(fontSize) }
    }

    // MARK: Command palette

    /// Opens the palette for the current workspace; its shortcut also closes it.
    @objc func showCommandPalette(_ sender: Any?) {
        if palettePresenter.isPresented { palettePresenter.dismiss(); return }
        if NSApp.isActive && !window.isKeyWindow {
            settingsWindow?.close()
            window.makeKeyAndOrderFront(nil)
        }
        presentPalette()
    }

    private func presentPalette(query: String = "", choices: PaletteChoices? = nil, prompt: PalettePrompt? = nil) {
        guard let content = window.contentView else { return }
        palettePresenter.anchor = content
        palettePresenter.centered = true
        palettePresenter.fallbackResponder = { [weak self] in self?.workspace.selectedView }
        palettePresenter.content = AnyView(CommandPalette(query: query, choices: choices, prompt: prompt,
            maxHeight: max(160, content.bounds.height - Self.topRow - 28)) { [weak self] in
                self?.paletteItems() ?? []
            })
        palettePresenter.show()
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        guard !(NSApp.keyWindow is SettingsWindow) else { return }
        window.toggleFullScreen(sender)
    }
    @objc func clearScrollback(_ sender: Any?) { terminalOperation(.clearPane, capability: "clearPane") }
    @objc func resetTerminal(_ sender: Any?) { terminalOperation(.resetPane, capability: "resetPane") }
    @objc func previousPrompt(_ sender: Any?) { scrollPrompt(previous: true) }
    @objc func nextPrompt(_ sender: Any?) { scrollPrompt(previous: false) }

    private func scrollPrompt(previous: Bool) {
        if workspace.selectedView?.scrollPrompt(previous: previous) != true {
            toast("No prompt boundary here. Shell integration adds prompt navigation to new shells.")
        }
    }

    /// Changes the server's authoritative terminal and all attached mirrors.
    private func terminalOperation(_ operation: Wire.Command.Op, capability: String) {
        guard let pane = workspace.selectedPane else { return }
        let source = workspace
        Task { [weak self] in
            guard let self else { return }
            await serverInspector.refresh(source.endpoint) { try await source.perform($0, reportingErrors: false) }
            guard serverInspector.supports(capability, at: source.endpoint) else {
                toast("The running server needs updating for this action. Existing sessions were preserved.")
                return
            }
            do { _ = try await source.perform(.init(op: operation, pane: pane.id)) }
            catch { showError(error.localizedDescription) }
        }
    }

    @objc func insertPath(_ sender: Any?) { choosePath(directory: false) }
    @objc func goDirectory(_ sender: Any?) { choosePath(directory: true) }

    /// Local panes use the system file picker; remote panes request an explicit
    /// remote path, preventing accidental insertion of a Mac filesystem path.
    private func choosePath(directory: Bool) {
        guard let target = workspace.selectedView else { return }
        if workspace.endpoint != .local {
            presentPalette(prompt: .init(title: directory ? "Go to Remote Directory" : "Insert Remote Path",
                placeholder: "/absolute/path", button: directory ? "Go" : "Insert",
                validate: { value in
                    TerminalView.shellPath(URL(fileURLWithPath: value)) != nil && value.hasPrefix("/")
                        ? nil : "Enter an absolute path on the remote machine."
                }, submit: { value in
                    let url = URL(fileURLWithPath: value)
                    if directory { target.goToDirectory(url) } else { target.insertPath(url) }
                }))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.prompt = directory ? "Go" : "Insert"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            if directory { target.goToDirectory(url) } else { target.insertPath(url) }
        }
    }

    private func projects() throws -> ProjectStore {
        let owner = applicationOwner ?? self
        if let store = owner.projectStore { return store }
        let store = try ProjectStore()
        owner.projectStore = store
        return store
    }

    @objc func saveProject(_ sender: Any?) {
        let source = workspace
        presentPalette(prompt: .init(title: "Save Project Layout", placeholder: "Project name", button: "Save",
            submit: { [weak self, weak source] name in
                guard let self, let source else { return }
                do { _ = try projects().save(snapshot: source.state, name: name, endpoint: source.endpoint); toast("Project layout saved") }
                catch { showError(error.localizedDescription) }
            }))
    }

    @objc func openProject(_ sender: Any?) {
        do {
            let store = try projects()
            presentPalette(choices: .init(title: "Projects", items: { [weak self, weak store] in
                guard let self, let store else { return [] }
                return store.projects.map { project in
                    PaletteItem(id: "project:" + project.id.uuidString, title: project.name,
                        detail: "\(project.tabs.count) tabs · \(project.endpoint.title)", symbol: "folder",
                        operation: .perform { self.restoreProject(project) })
                } + [.init(id: "manage_projects", title: "Manage Saved Projects…", detail: "Rename or remove layouts", symbol: "folder.badge.gearshape",
                           operation: .choices { self.projectManagement(store) })]
            }, placeholder: "Search projects…"))
        } catch { showError(error.localizedDescription) }
    }

    private func projectManagement(_ store: ProjectStore) -> PaletteChoices {
        .init(title: "Manage Projects", items: { [weak self, weak store] in
            guard let self, let store else { return [] }
            return store.projects.map { project in
                .init(id: "manage:" + project.id.uuidString, title: project.name, detail: "", symbol: "folder", operation: .choices {
                    .init(title: project.name, items: {
                        [.init(id: "rename_project", title: "Rename…", detail: "", symbol: "pencil", operation: .prompt {
                            .init(title: "Rename Project", placeholder: "Name", initial: project.name, submit: { name in
                                do { try store.rename(project.id, to: name) } catch { self.showError(error.localizedDescription) }
                            })
                        }), .init(id: "delete_project", title: "Remove Saved Layout", detail: "Running tabs and jobs stay open", symbol: "trash", destructive: true,
                                  operation: .perform { do { try store.remove(project.id) } catch { self.showError(error.localizedDescription) } })]
                    })
                })
            }
        })
    }

    private func restoreProject(_ project: Project) {
        projectRestoreTask?.cancel()
        if case .ssh(let host) = project.endpoint, !machines.hosts.contains(host) { machines.add(host) }
        machines.select(project.endpoint)
        projectRestoreTask = Task { [weak self] in
            guard let self, !windowClosed else { return }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while machines.current != project.endpoint || workspace.transport == .disconnected {
                    guard !windowClosed, ContinuousClock.now < deadline else { throw WorkspaceCommandError("The project machine is not connected.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let source = workspace
                await serverInspector.refresh(source.endpoint) { try await source.perform($0, reportingErrors: false) }
                try Task.checkCancellation()
                guard !windowClosed, source.transport != .disconnected else {
                    throw WorkspaceCommandError("The project machine disconnected. Reconnect and try again.")
                }
                guard serverInspector.supports("resizeSplitWeights", at: source.endpoint),
                      serverInspector.supports("splitCwd", at: source.endpoint) else {
                    throw WorkspaceCommandError("Update the running server to restore saved layouts. Existing sessions stay open.")
                }
                let restorer = ProjectRestorer(command: { try await source.perform($0) }, state: { source.state }, select: { source.select($0) })
                _ = try await restorer.restore(project)
                toast("Opened project in new shells")
            } catch { showError(error.localizedDescription) }
        }
    }

    @objc func showActivity(_ sender: Any?) {
        let center = (applicationOwner ?? self).activityCenter
        presentPalette(choices: .init(title: "Activity", items: { [weak self, weak center] in
            guard let self, let center else { return [] }
            return center.activities.map { item in
                .init(id: "activity:" + item.id.pane, title: item.title.isEmpty ? item.program : item.title,
                      detail: item.status == .blocked ? "Waiting for input" : item.status.rawValue.capitalized,
                      symbol: "waveform.path", operation: .perform {
                    if !self.focusActivity(endpoint: item.id.endpoint, tab: item.tab, pane: item.id.pane) {
                        self.toast("That pane is no longer available.")
                    }
                })
            }
        }, placeholder: "Search activity…"))
    }

    /// Notification taps wait briefly for initial attachment, then route by stable IDs.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let tab = info["tab"] as? String, let pane = info["pane"] as? String else { return }
        let host = info["host"] as? String
        for _ in 0..<100 {
            if await focusActivity(endpoint: host.map(Endpoint.ssh) ?? .local, tab: tab, pane: pane) { return }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
    }

    /// Focus an existing known pane; stale notifications never create connections or shells.
    @discardableResult func focusActivity(endpoint: Endpoint, tab: String, pane: String, present: Bool = true) -> Bool {
        let candidates = windowOwners.sorted { ($0.window?.isKeyWindow == true ? 0 : 1) < ($1.window?.isKeyWindow == true ? 0 : 1) }
        for controller in candidates {
            guard let source = controller.machines.allWorkspaces.first(where: { $0.endpoint == endpoint }),
                  source.state.tabs.contains(where: { $0.id == tab && $0.panes.contains(where: { $0.id == pane }) }) else { continue }
            controller.machines.select(endpoint)
            source.select(tab)
            source.focus(pane)
            if present { controller.window.makeKeyAndOrderFront(nil); NSApp.activate() }
            return true
        }
        return false
    }

    @objc func checkUpdates(_ sender: Any?) {
        (applicationOwner ?? self).appUpdater.checkNow()
    }

    private var machineSettings: some View {
        MachineSettingsView(machines: machines, inspector: serverInspector,
            refresh: { [weak self] endpoint in
                guard let self, let source = machines.allWorkspaces.first(where: { $0.endpoint == endpoint }) else { return }
                Task {
                    await serverInspector.refresh(endpoint) { try await source.perform($0, reportingErrors: false) }
                    source.serverCapabilities = Set(serverInspector.replies[endpoint]?.capabilities ?? [])
                    workspaceStateChanged()
                }
            }, copyDiagnostics: { [weak self] endpoint in self?.copyReport(for: endpoint) },
            openLogs: { NSWorkspace.shared.open(Paths.serverLog) })
    }

    private var diagnostics: Diagnostics {
        if let diagnosticsWindow, diagnosticsWindow.window?.isKeyWindow == true { return diagnosticsWindow.screen.snapshot.report }
        return diagnosticSnapshot(for: machines.current).report
    }

    /// Report facts for the inspected endpoint, independently of the active terminal machine.
    func diagnosticReport(for endpoint: Endpoint) -> Diagnostics {
        let reply = serverInspector.replies[endpoint]
        let source = machines.allWorkspaces.first { $0.endpoint == endpoint }
        let sensitiveHosts = machines.hosts + { if case .ssh(let host) = endpoint { return [host] }; return [] }()
        let server = DiagnosticServer(version: reply?.serverVersion,
            bundledVersion: endpoint == .local ? LocalServer.bundledVersion : nil,
            wireVersion: reply?.protocolVersion.map(Int.init), transport: source?.transport ?? .disconnected,
            connected: source?.transport != nil && source?.transport != .disconnected,
            logURL: endpoint == .local ? Paths.serverLog : nil, sensitiveHosts: sensitiveHosts,
            checkedAt: serverInspector.checkedAt[endpoint], machine: endpoint.title,
            pid: reply?.serverPID.map(Int.init))
        var report = Diagnostics(server: server, configURL: Paths.config, stateURL: Paths.state,
                                 logURL: Paths.serverLog, configIssueCount: Config.current.issues.count)
        report.launchToFirstPaneMS = Launch.firstPaneMilliseconds
        return report
    }

    /// Read-only diagnostics retain the invoking window and selected machine scope.
    @objc func showDiagnostics(_ sender: Any?) {
        let controller = diagnosticsController()
        controller.window?.nextResponder = self
        controller.present()
    }

    /// Construct without showing so previews and lifetime tests use the real window.
    func diagnosticsController() -> DiagnosticsWindowController {
        if let diagnosticsWindow { return diagnosticsWindow }
        let controller = DiagnosticsWindowController(machine: machines.current,
            sample: { [weak self] endpoint in
                guard let self else { preconditionFailure("Diagnostics owner must outlive its window") }
                return diagnosticSnapshot(for: endpoint)
            }, probe: { [weak self] endpoint in await self?.refreshDiagnosticServer(endpoint) },
            copy: { Self.copyText($0.text) }, export: { [weak self] in self?.exportReport($0) },
            openLogs: { NSWorkspace.shared.open(Paths.serverLog) },
            resetRendering: { [weak self] endpoint in
                self?.machines.allWorkspaces.first { $0.endpoint == endpoint }?.attachedViews.forEach { $0.resetRenderingDiagnostics() }
            }, clearIssues: { [weak self] in
                self?.diagnosticIssues.clear()
                self?.issuesClearedAt = Date()
            })
        diagnosticsWindow = controller
        return controller
    }

    /// Never prepares SSH or creates a workspace: a refresh probes an existing connection only.
    private func refreshDiagnosticServer(_ endpoint: Endpoint) async {
        guard let source = machines.allWorkspaces.first(where: { $0.endpoint == endpoint }), source.transport != .disconnected else {
            diagnosticIssues.record(subsystem: "Diagnostics", message: "No active connection for the selected machine.")
            return
        }
        await serverInspector.refresh(endpoint) { try await source.perform($0, reportingErrors: false) }
        source.serverCapabilities = Set(serverInspector.replies[endpoint]?.capabilities ?? [])
        if let error = serverInspector.errors[endpoint] {
            diagnosticIssues.record(subsystem: "Server", message: error, sensitiveHosts: machines.hosts)
        }
    }

    private var issuesClearedAt = Date.distantPast

    /// Samples existing client mirrors and bounded counters without requesting terminal text.
    func diagnosticSnapshot(for endpoint: Endpoint) -> DiagnosticsSnapshot {
        let source = machines.allWorkspaces.first { $0.endpoint == endpoint }
        let views = Dictionary(uniqueKeysWithValues: (source?.attachedViews ?? []).map { ($0.paneID, $0) })
        let panes: [DiagnosticsSnapshot.Pane] = (source?.state.tabs.flatMap(\.panes) ?? []).map { pane in
            let view = views[pane.id]
            return .init(id: pane.id, title: "Pane \(pane.id)", connection: view?.connectionDescription ?? "Not attached in this window", rendering: view?.renderingDiagnostics)
        }
        let appIssues = diagnosticIssues.entries.map {
            DiagnosticsSnapshot.Issue(id: $0.id.uuidString, date: $0.lastSeen, subsystem: $0.subsystem, message: $0.message, count: $0.count)
        }
        let rendererIssues = panes.flatMap { pane in
            (pane.rendering?.issues ?? []).filter { $0.timestamp > issuesClearedAt }.map {
                DiagnosticsSnapshot.Issue(id: $0.id.uuidString, date: $0.timestamp, subsystem: "Renderer · \(pane.id)", message: $0.message, count: $0.count)
            }
        }
        let issues = Array((appIssues + rendererIssues).sorted { $0.date > $1.date }.prefix(100))
        var report = diagnosticReport(for: endpoint)
        report.renderingSummary = panes.compactMap { pane in
            guard let stats = pane.rendering else { return nil }
            func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.2f ms", $0) } ?? "unavailable" }
            return "Pane \(pane.id): \(stats.device), \(stats.drawableWidth)x\(stats.drawableHeight), submitted \(stats.framesSubmitted), completed \(stats.framesCompleted), failed \(stats.framesFailed), pending \(stats.pendingFrame), in-flight \(stats.inFlight), CPU \(milliseconds(stats.lastCPUFrameMS)), max CPU \(milliseconds(stats.maxCPUFrameMS)), GPU \(milliseconds(stats.lastGPUFrameMS)), atlas \(stats.atlasBytes) bytes, buffers \(stats.bufferBytes) bytes; deferred \(stats.deferred.keys.sorted().map { "\($0)=\(stats.deferred[$0] ?? 0)" }.joined(separator: ", "))"
        }
        report.recentIssueSummary = issues.map { "\($0.date.formatted(.iso8601)) \($0.subsystem) ×\($0.count): \($0.message)" }
        return DiagnosticsSnapshot(machine: endpoint, title: endpoint.title, symbol: machines.deviceIcons.symbol(for: endpoint),
            machines: ([Endpoint.local] + machines.hosts.map(Endpoint.ssh)).map { .init(endpoint: $0, title: $0.title) },
            report: report, server: serverInspector.replies[endpoint], checkedAt: serverInspector.checkedAt[endpoint],
            refreshError: source?.transport == nil || source?.transport == .disconnected
                ? "No active control connection. Open this machine in Koi to connect." : serverInspector.errors[endpoint],
            configurationIssues: Config.current.issues.map { Diagnostics.redact($0, sensitiveHosts: machines.hosts) },
            panes: panes, issues: issues)
    }

    private func copyReport(for endpoint: Endpoint) { Self.copyText(diagnosticSnapshot(for: endpoint).report.text) }

    private static func installCLI() throws { _ = try CLIInstaller.install() }

    /// Copies the existing redacted support report from the invoking window.
    @objc func copyDiagnostics(_ sender: Any?) { Self.copyText(diagnostics.text) }

    /// Opens the local server log in the user's chosen viewer.
    @objc func openLogs(_ sender: Any?) { NSWorkspace.shared.open(Paths.serverLog) }

    /// Exports the same redacted report as Copy Diagnostics to a user-chosen file.
    @objc func exportDiagnostics(_ sender: Any?) { exportReport(diagnostics) }

    private func exportReport(_ report: Diagnostics) {
        // Capture the initiating window before a modal save panel changes focus.
        let target = diagnosticsWindow?.window?.isKeyWindow == true ? diagnosticsWindow?.window
            : settingsWindow?.isKeyWindow == true ? settingsWindow : window
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "koi-diagnostics.txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try report.exportFromUserAction(to: destination) }
        catch { showError(error.localizedDescription, subsystem: "Diagnostics", in: target) }
    }

    /// Auxiliary tools use the same floating presentation in the invoking window.
    private func presentSupport<Content: View>(_ view: Content) {
        let parent = settingsWindow?.isKeyWindow == true ? settingsWindow?.contentView : window.contentView
        guard let parent else { return }
        palettePresenter.dismiss()
        palettePresenter.anchor = parent
        palettePresenter.centered = true
        palettePresenter.content = AnyView(view)
        palettePresenter.show()
    }

    /// Adapts the same actions used by menus/keybindings and adds contextual
    /// workspace operations. Catalog evaluation reads live, local app state.
    private func paletteItems() -> [PaletteItem] {
        let ws = workspace
        let tab = ws.tab(ws.selectedTab)?.tab
        let group = ws.tab(ws.selectedTab)?.group
        let pane = ws.selectedPane
        let hasSplits = (tab?.panes.count ?? 0) > 1
        var entries: [PaletteItem] = []
        if let view = ws.attachedViews.first(where: { $0.paneID == pane?.id }) {
            entries.append(.init(id: "reconnect_pane", title: "Reconnect Pane", detail: "Refresh the display; keep the process running",
                                 symbol: "arrow.clockwise", category: .panes,
                                 operation: .perform { [weak view] in view?.reconnect() }))
            entries.append(.init(id: "pane_control", title: view.observing ? "Take Control of Pane" : "Observe Pane",
                                 detail: view.observing ? "Allow typing and terminal resizing" : "Watch output without changing the terminal",
                                 symbol: view.observing ? "cursorarrow" : "eye", category: .panes,
                                 operation: .perform { [weak view] in
                                     guard let view else { return }
                                     if view.observing { view.takeControl() } else { view.observe() }
                                 }))
        }
        let ordered = machines.allWorkspaces.sorted {
            if $0.endpoint == machines.current { return $1.endpoint != machines.current }
            if $1.endpoint == machines.current { return false }
            return $0.endpoint.key < $1.endpoint.key
        }
        for source in ordered {
            if case .ssh(let host) = source.endpoint, machines.status[host] != .ready { continue }
            entries += PaletteSearch.workItems(in: source) { [weak self, weak source] tabID, paneID in
                guard let self, let source, source.tab(tabID) != nil else { return }
                source.select(tabID)
                if let paneID { source.focus(paneID) }
                self.machines.select(source.endpoint)
            }
        }
        entries += machineItems()

        for action in Action.allCases where action != .commandPalette {
            var enabled = true
            var unavailable = "Not available here"
            switch action {
            case .clearScrollback, .resetTerminal:
                let capability = action == .clearScrollback ? "clearPane" : "resetPane"
                enabled = pane != nil && serverInspector.supports(capability, at: ws.endpoint)
                unavailable = pane == nil ? "No focused pane" : "Requires an updated running server"
            case .saveProject:
                enabled = !ws.state.tabs.isEmpty
            case .copy, .selectAll, .find, .previousPrompt, .nextPrompt, .insertPath, .goDirectory:
                enabled = pane != nil
                unavailable = "No focused pane"
            case .toggleSidebar: if !Config.current.tabs.isVertical { continue }
            case .toggleZoom, .nextPane, .previousPane:
                enabled = hasSplits
                unavailable = "Requires multiple panes"
            case .nextTab, .previousTab:
                enabled = ws.state.tabs.count > 1
                unavailable = "Requires another tab"
            case .focusSplitLeft, .focusSplitRight, .focusSplitUp, .focusSplitDown:
                let direction: SplitContainerView.Direction = switch action {
                case .focusSplitLeft: .left
                case .focusSplitRight: .right
                case .focusSplitUp: .up
                default: .down
                }
                enabled = pane.map { card.pane(from: $0.id, toward: direction) != nil } ?? false
                unavailable = "No pane in that direction"
            case .closePane, .closeTab, .newSplit, .newSplitDown, .paste:
                enabled = pane != nil
                unavailable = "No focused pane"
            default: break
            }
            var title = action.title
            if action == .toggleZoom && ws.zoomedPane != nil { title = "Unzoom Pane" }
            if action == .toggleSidebar { title = sidebarShown ? "Hide Sidebar" : "Show Sidebar" }
            if action == .increaseFontSize { title = "Increase Text Size" }
            if action == .decreaseFontSize { title = "Decrease Text Size" }
            if action == .resetFontSize { title = "Reset Text Size" }
            entries.append(.init(id: action.rawValue, title: title, detail: enabled ? action.paletteCategory.rawValue : unavailable, symbol: action.paletteSymbol,
                                 keywords: [action.paletteCategory.rawValue, action.rawValue.replacingOccurrences(of: "_", with: " "),
                                            action == .openConfig ? "preferences settings" : "",
                                            [.increaseFontSize, .decreaseFontSize, .resetFontSize].contains(action) ? "terminal font size text" : ""],
                                 shortcut: Config.current.bind(action).symbols,
                                 category: action.paletteCategory,
                                 destructive: action == .closePane || action == .closeTab, enabled: enabled,
                                 operation: .perform { [weak self] in
                                     if self != nil { NSApp.sendAction(action.selector, to: nil, from: nil) }
                                 }))
        }
        if let tab {
            entries.append(.init(id: "rename_tab", title: "Rename Tab…", detail: "Tabs", symbol: "pencil",
                                 keywords: ["name label"], operation: .prompt {
                PalettePrompt(title: "Rename Tab", placeholder: "Tab name", initial: tab.name ?? "", button: "Rename",
                              validate: { value in
                                  guard ws.tab(tab.id) != nil else { return "This tab has closed." }
                                  return value.isEmpty ? "Enter a tab name." : nil
                              }, submit: { ws.renameTab(tab.id, to: $0) })
            }))
            if tab.name?.isEmpty == false {
                entries.append(.init(id: "clear_tab_name", title: "Clear Tab Name", detail: "Tabs", symbol: "eraser",
                                     operation: .perform { ws.renameTab(tab.id, to: "") }))
            }
            entries.append(.init(id: "close_other_tabs", title: "Close Other Tabs", detail: "Tabs", symbol: "rectangle.stack",
                                 destructive: true, enabled: ws.state.tabs.count > 1,
                                 operation: .perform { ws.closeOtherTabs(tab.id) }))
        }
        if let group {
            entries.append(.init(id: "rename_group", title: "Rename Group…", detail: group.name, symbol: "pencil",
                                 operation: .prompt {
                PalettePrompt(title: "Rename Group", placeholder: "Group name", initial: group.name, button: "Rename",
                              validate: { value in
                                  guard ws.state.items.contains(where: {
                                      if case .group(let current) = $0 { return current.id == group.id }
                                      return false
                                  }) else { return "This group has closed." }
                                  return value.isEmpty ? "Enter a group name." : nil
                              }, submit: { ws.renameGroup(group.id, to: $0) })
            }))
            let collapsed = ws.collapsed.contains(group.id)
            entries += [
                .init(id: "toggle_group", title: collapsed ? "Expand Group" : "Collapse Group", detail: group.name,
                      symbol: collapsed ? "chevron.down" : "chevron.up", operation: .perform { ws.toggleCollapsed(group.id) }),
                .init(id: "ungroup", title: "Ungroup Tabs", detail: group.name, symbol: "rectangle.3.group",
                      operation: .perform { ws.ungroup(group.id) }),
                .init(id: "close_group", title: "Close Group", detail: group.name, symbol: "xmark",
                      destructive: true, operation: .perform { ws.closeGroup(group.id) }),
            ]
        }
        if let pane {
            entries += [
                .init(id: "copy_directory", title: "Copy Working Directory", detail: pane.cwd, symbol: "folder",
                      keywords: ["path pwd cwd clipboard"], category: .terminal, operation: .perform { Self.copyText(pane.cwd) }),
                .init(id: "copy_pane_id", title: "Copy Pane ID", detail: pane.id, symbol: "number",
                      keywords: ["identifier clipboard"], category: .terminal, operation: .perform { Self.copyText(pane.id) }),
            ]
        }
        entries += [
            .init(id: "switch_machine", title: "Switch Machine…", detail: "Machines", symbol: "desktopcomputer",
                  keywords: ["host remote ssh computer"], category: .machines, operation: .choices { [weak self] in
                      PaletteChoices(title: "Switch Machine", items: { self?.machineItems() ?? [] }, placeholder: "Search machines…")
                  }),
            .init(id: "add_machine", title: "Add Machine…", detail: "Machines", symbol: "plus",
                  keywords: ["host remote ssh computer"], category: .machines, operation: .prompt { [weak self] in
                      PalettePrompt(title: "Add Machine", placeholder: "SSH alias or user@host", button: "Add",
                                    suggestions: Remote.configuredHosts().filter { !(self?.machines.hosts.contains($0) ?? false) },
                                    validate: { value in
                                        value.isEmpty || value.hasPrefix("-") || value.contains(where: \.isWhitespace)
                                            ? "Enter an SSH alias or user@host." : nil
                                    }, submit: { self?.machines.add($0) })
                  }),
            .init(id: "tabs_side", title: "Use Left Tabs", detail: Config.current.tabs == .side ? "Current placement" : "Appearance", symbol: "sidebar.left",
                  keywords: ["tab placement position left sidebar layout"], category: .appearance, enabled: Config.current.tabs != .side,
                  operation: .perform { [weak self] in self?.changePreference("tabs", "side") }),
            .init(id: "tabs_top", title: "Use Top Tabs", detail: Config.current.tabs == .top ? "Current placement" : "Appearance", symbol: "rectangle.topthird.inset.filled",
                  keywords: ["tab placement position horizontal layout"], category: .appearance, enabled: Config.current.tabs != .top,
                  operation: .perform { [weak self] in self?.changePreference("tabs", "top") }),
            .init(id: "tabs_right", title: "Use Right Tabs", detail: Config.current.tabs == .right ? "Current placement" : "Appearance", symbol: "sidebar.right",
                  keywords: ["tab placement position right sidebar layout"], category: .appearance, enabled: Config.current.tabs != .right,
                  operation: .perform { [weak self] in self?.changePreference("tabs", "right") }),
            .init(id: "edit_config", title: "Edit Config File", detail: "Settings", symbol: "doc.text",
                  category: .settings,
                  operation: .perform { [weak self] in self?.openConfig(nil) }),
        ]
        return entries
    }

    #if KOID
    /// Koid exercises the same entries and prompts without injecting screen input.
    private func previewPalette(_ request: [String: String]) {
        if let path = request["inspect"] {
            var state: [String: Any] = ["presented": palettePresenter.isPresented,
                "matches": PaletteSearch.results(paletteItems(), query: request["query"] ?? "", recent: []).map(\.id)]
            state["tab"] = workspace.selectedTab
            state["pane"] = workspace.focusedPane
            state["visible"] = window?.occlusionState.contains(.visible) == true
            state["panes"] = diagnosticSnapshot(for: machines.current).panes.map { pane -> [String: Any] in
                ["id": pane.id, "connection": pane.connection,
                 "frames": pane.rendering?.framesSubmitted ?? 0,
                 "drawable": [pane.rendering?.drawableWidth ?? 0, pane.rendering?.drawableHeight ?? 0]]
            }
            if let data = try? JSONSerialization.data(withJSONObject: state) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            return
        }
        palettePresenter.dismiss()
        guard let id = request["id"] else { presentPalette(query: request["query"] ?? ""); return }
        let catalog = paletteItems()
        let home = PalettePresentation.home(items: { [weak self] in self?.paletteItems() ?? [] })
        guard let item = (catalog + home.flatMap(\.items)).first(where: { $0.id == id && $0.enabled }) else { return }
        switch item.operation {
        case .perform(let action): action()
        case .prompt(let make):
            let prompt = make()
            let value = (request["value"] ?? prompt.initial).trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.validate(value) == nil { prompt.submit(value) }
        case .choices(let make): presentPalette(choices: make())
        }
    }
    #endif

    private func machineItems() -> [PaletteItem] {
        ([Endpoint.local] + machines.hosts.map { .ssh($0) }).map { endpoint in
            var detail = endpoint == machines.current ? "Current machine" : "Switch machine"
            if case .ssh(let host) = endpoint {
                switch machines.status[host] {
                case .connecting: detail = "Connecting…"
                case .failed(let error): detail = "Connection failed · " + error
                default: break
                }
            }
            return .init(id: "machine:\(endpoint.key)", title: endpoint.title, detail: detail, symbol: machines.deviceIcons.symbol(for: endpoint),
                         keywords: ["machine host remote ssh computer"], kind: .machine,
                         operation: .perform { [weak self] in self?.machines.select(endpoint) })
        }
    }

    private static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}
