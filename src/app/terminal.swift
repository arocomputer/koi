import AppKit
import GhosttyVt
import QuartzCore
import UniformTypeIdentifiers

/// One terminal pane: attaches to a session on the server, mirrors it in its
/// own libghostty-vt terminal, draws it with Metal on the display's refresh,
/// and turns keyboard, IME, mouse and paste into bytes for the session.
///
/// The pane never resizes its terminal on its own: it asks the session to,
/// and resizes when the session says it has (`.resized`), so its terminal
/// sees resizes at the same point in the output as the server's.
///
/// Attachment negotiates compatibility first. Observers never send terminal
/// input or resize the shared PTY until the user explicitly takes control.
@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    private let metalLayer = CAMetalLayer()
    private var renderer: Renderer!
    /// A bounded local renderer sample; never attaches a pane or reads its text.
    var renderingDiagnostics: RenderDiagnosticsSnapshot? { renderer?.diagnostics }
    var rendererAvailable: Bool { renderer != nil }
    func resetRenderingDiagnostics() { renderer?.resetDiagnostics() }
    private var metrics: FontMetrics
    /// What `metrics` was built from, so unchanged inputs reuse it.
    private var metricsKey: (size: CGFloat, scale: CGFloat)
    /// The first snapshot showed an empty screen: the cursor is held back
    /// until the shell's first output or input, so it does not sit alone
    /// before the prompt however slowly the shell starts; `cursorGrace` only
    /// bounds a shell that never prints.
    private(set) var cursorSuppressed = false
    private var suppression: Task<Void, Never>?
    private var hasRestored = false
    static let cursorGrace: UInt64 = 2_000_000_000
    private(set) var terminal: VTTerminal?
    private var connection: PaneConnection?
    private var wantsConnection = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectSignal: UUID?
    private var connectingTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var reconnectDelay: UInt64 = 300_000_000
    private var handshakeTask: Task<Void, Never>?
    private var restoredConnection = false
    /// Koid observes remote work by default; old remote servers also require
    /// an explicit claim because they cannot arbitrate between clients.
    private(set) var observing = false
    private var wantsObservation = false
    private(set) var supportsOwnership = false
    var canControl: Bool { !observing && restoredConnection && connection?.allowsInput == true }
    /// The pane on the server this view shows, and where that server is.
    let paneID: String
    let endpoint: Endpoint
    private let controller: String
    private var requested: GridSize?
    /// Each animation owns a hold; the session resizes only after all owners
    /// finish, even if a terminal moves between tabs during an animation.
    private var resizeHoldCount = 0
    var holdsResizes: Bool { resizeHoldCount > 0 }

    /// Acquire one owner's hold; every acquisition needs a matching release.
    func beginResizeHold() { resizeHoldCount += 1 }

    /// Resume resize requests only after the last owner releases its hold.
    func endResizeHold() {
        guard resizeHoldCount > 0 else { return }
        resizeHoldCount -= 1
        if !holdsResizes { requestResize() }
    }
    /// Set by anything that changes what the pane shows; it also wakes the
    /// display link, which pauses itself once a tick finds nothing to do.
    private var needsRender = true {
        didSet { if needsRender { displayLink?.isPaused = false } }
    }
    private var forceRender = true
    private var displayLink: CADisplayLink?
    private var occlusionObserver: NSObjectProtocol?
    private var commandKeyUpMonitor: Any?
    private var focused = false
    private var accessibilityDocument: TerminalAccessibilityText?
    private var accessibilityObserved = false
    private var accessibilityNotificationTask: Task<Void, Never>?

    /// Effective transport/session state for pane chrome; reads are valid even
    /// before a coordinator installs its callback.
    private(set) var connectionDescription = "Offline"
    var onConnectionChange: (() -> Void)?

    /// Publish transitions once; coordinators read the current description.
    private func describeConnection(_ description: String) {
        guard connectionDescription != description else { return }
        connectionDescription = description
        onConnectionChange?()
    }

    private let keyboard = TerminalKeyboard()
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private var marked = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private let composition = CompositionView(frame: .zero)
    /// Text that interpretKeyEvents inserted during the current keyDown;
    /// nil outside keyDown.
    private var inserted: [String]?
    private var scrollRemainder: CGFloat = 0
    private var pressedButtons = 0
    private var selection: TerminalSelection?
    private var lastSelectionScroll: TimeInterval = 0
    /// A drag keeps its initial routing even if Shift changes mid-gesture.
    private var selectingWithMouse = false
    /// The find bar and its parts, made on first use.
    private var findBar: NSView?
    private var findField: NSTextField?
    private var findLabel: NSTextField?
    /// Instant typing, for panes on other machines; nil locally, where the
    /// echo is as fast as a prediction would be.
    private var predictor: Prediction?
    /// With KOI_PERF set: when input was last sent, to time the echo.
    private static let perf = ProcessInfo.processInfo.environment["KOI_PERF"] != nil
    private var inputSentAt: Date?

    var fontSize: CGFloat = 13 { didSet { updateMetrics() } }

    /// Force a fresh frame after terminal display state changes.
    func redraw() { forceRender = true; needsRender = true }

    /// Rebuild metrics, restore fixed colors and history/input defaults, and
    /// repaint the mirror after a configuration reload.
    func reloadAppearance() {
        updateMetrics(force: true)
        terminal?.applyTheme()
        applyTerminalConfiguration()
        redraw()
    }
    /// Apply the mirror's engine budget. The server side of the same setting
    /// is sent by the app coordinator over the workspace's control connection.
    private func applyTerminalConfiguration() {
        guard let terminal else { return }
        var bytes = min(max(Config.current.scrollbackMB, 1), 1024) * 1024 * 1024
        ghostty_terminal_set(terminal.raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
        accessibilityChanged()
    }

    /// Inset of the grid from the pane's edges, in points.
    let padding: CGFloat = 12

    /// A confirmed child exit only; transport and snapshot failures never end a process.
    var onEnd: (() -> Void)?
    /// The view took the keyboard (a click, or Tab focus).
    var onFocus: (() -> Void)?

    /// Build the initial atlas at the intended font size, before attachment,
    /// instead of allocating a default atlas only to discard it on first show.
    init(pane: String, at endpoint: Endpoint, fontSize: CGFloat = 13, controller: String = UUID().uuidString) {
        paneID = pane
        self.endpoint = endpoint
        self.controller = controller
        observing = endpoint != .local
        wantsObservation = Paths.isDev && endpoint != .local
        self.fontSize = fontSize
        if endpoint != .local { predictor = Prediction() }
        metrics = FontMetrics(size: fontSize, scale: 2)
        metricsKey = (fontSize, 2)
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        renderer = Renderer(metrics: metrics)
        renderer?.onFrameNeeded = { [weak self] in self?.redraw() }
        metalLayer.device = renderer?.device
        ghostty_mouse_encoder_new(nil, &mouseEncoder)
        ghostty_mouse_event_new(nil, &mouseEvent)
        addSubview(composition)
        registerForDraggedTypes([.fileURL, .string])
    }

    isolated deinit {
        reconnectTask?.cancel()
        handshakeTask?.cancel()
        connectingTask?.cancel()
        suppression?.cancel()
        accessibilityNotificationTask?.cancel()
        connection?.close()
        displayLink?.invalidate()
        if let commandKeyUpMonitor { NSEvent.removeMonitor(commandKeyUpMonitor) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_mouse_event_free(mouseEvent)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var acceptsFirstResponder: Bool { true }
    /// Clicks and drags in the terminal are the terminal's, never a window move.
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    // MARK: Session

    /// Attaches to the pane on the server; the server sends its screen and
    /// scrollback, then its output as it happens.
    func attach() {
        if !wantsConnection { describeConnection("Connecting") }
        wantsConnection = true
        connectPane()
    }

    /// A reconnect asks for a fresh snapshot of the same running pane.
    /// Connection setup runs away from the main actor. A late result after
    /// detach is closed; the current geometry is sampled only when it arrives.
    private func connectPane() {
        guard wantsConnection, connection == nil, connectingTask == nil else { return }
        let endpoint = endpoint, generation = UUID()
        connectionGeneration = generation
        connectingTask = Task { [weak self] in
            let socket = await endpoint.connectAsync()
            guard let self, !Task.isCancelled, self.wantsConnection, self.connectionGeneration == generation else {
                socket?.close()
                return
            }
            self.connectingTask = nil
            guard let socket else { self.scheduleReconnect(); return }
            self.stopAwaitingServer()
            // Negotiation zeros this grid for observers. Only the acknowledged
            // owner may send the settled size after restoring the snapshot.
            let fitted = self.holdsResizes ? nil : self.fittedGrid()
            self.requested = nil
            var req = Self.openRequest(pane: self.paneID, grid: fitted,
                                       cellWidth: self.metrics.cellWidth, cellHeight: self.metrics.cellHeight)
            req.controller = self.controller
            let c = PaneConnection(req, socket: socket, observer: self.wantsObservation,
                                   legacyObserver: endpoint != .local, negotiate: true)
            self.connection = c
            self.restoredConnection = false
            c.onEvents = { [weak self, weak c] events in
                guard let self, let c, self.connection === c else { return }
                self.handle(events)
            }
            self.handshakeTask?.cancel()
            self.handshakeTask = Task { [weak self, weak c] in
                var deadline = ConnectionDeadline(now: ProcessInfo.processInfo.systemUptime)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, let c, self.connection === c, !self.restoredConnection else { return }
                    if deadline.stalled(receivedBytes: c.receivedBytes, now: ProcessInfo.processInfo.systemUptime) {
                        self.retryConnection("Connection lost — initialization stalled")
                        return
                    }
                }
            }
        }
    }

    /// Explicitly transfers control. Legacy servers can only enforce this in
    /// this client; modern servers acknowledge the transfer before any writes.
    func takeControl() { wantsObservation = false; connection?.takeControl() }

    /// Keep receiving output while giving up all input and resize privileges.
    func observe() { wantsObservation = true; connection?.releaseControl() }

    /// Rebuild the mirror without ending or sending input to the remote process.
    func reconnect() {
        wantsConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectingTask?.cancel()
        connectingTask = nil
        connectionGeneration = UUID()
        handshakeTask?.cancel()
        connection?.close()
        connection = nil
        requested = nil
        connectPane()
    }

    /// A failed attachment is a connection failure, never evidence of child exit.
    /// Preserve retry history until a complete snapshot has actually restored.
    /// Only a failing transport counts against the host's link: an answer the
    /// server sent (a failure message, a bad snapshot) arrived over a working one.
    private func retryConnection(_ description: String, transportFailed: Bool = true) {
        handshakeTask?.cancel()
        handshakeTask = nil
        if !restoredConnection, transportFailed { connection?.reportFailure(at: endpoint) }
        connection?.close()
        connection = nil
        requested = nil
        restoredConnection = false
        setFocused(false)
        if wantsConnection { scheduleReconnect(description) }
        else { describeConnection(description) }
    }

    /// The open request for a grid, or for no grid yet: zero columns and rows
    /// attach without resizing the pane.
    static func openRequest(pane: String, grid: GridSize?, cellWidth: Int, cellHeight: Int) -> Wire.OpenRequest {
        Wire.OpenRequest(pane: pane, cols: grid?.cols ?? 0, rows: grid?.rows ?? 0,
                         cellWidth: UInt32(cellWidth), cellHeight: UInt32(cellHeight))
    }

    private func scheduleReconnect(_ description: String = "Connection lost — retrying") {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        describeConnection(description)
        reconnectDelay = min(reconnectDelay * 2, 5_000_000_000)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.wantsConnection else { return }
            self.reconnectTask = nil
            self.connectPane()
        }
        // A server appearing or the network changing is tried at once.
        if reconnectSignal == nil {
            reconnectSignal = Reconnect.observe { [weak self] in
                guard let self, self.wantsConnection else { return }
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                self.connectPane()
            }
        }
    }

    private func stopAwaitingServer() {
        if let reconnectSignal { Reconnect.stopObserving(reconnectSignal) }
        reconnectSignal = nil
    }

    /// Detaches, leaving the pane's shell running.
    func detach() {
        wantsConnection = false
        stopAwaitingServer()
        reconnectTask?.cancel()
        reconnectTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        connectingTask?.cancel()
        connectingTask = nil
        connectionGeneration = UUID()
        connection?.close()
        connection = nil
        showCursor()
        setFocused(false)
        selection?.cancel()
        describeConnection("Offline")
    }

    /// Apply one ordered stream batch; only a confirmed exit invokes `onEnd`.
    func handle(_ events: [PaneConnection.Event]) {
        // A batch can end in disconnect/exit after output; invalidate before
        // those early returns so AX and the last frame retain that output.
        accessibilityChanged()
        needsRender = true
        // The focused pane draws output as it arrives rather than on the next
        // display tick: up to one frame less between a keystroke and its echo.
        // Batches already coalesce per main-loop turn, so bursts stay bounded.
        defer { if focused, connection != nil, window?.occlusionState.contains(.visible) == true { renderNow(inTransaction: false) } }
        for e in events {
            switch e {
            case .negotiated(let ownership, let observing):
                supportsOwnership = ownership
                self.observing = observing
                wantsObservation = observing
            case .ownership(let owns):
                observing = !owns
                wantsObservation = !owns
                requested = nil
                predictor?.reset()
                pushOverlay()
                if restoredConnection {
                    describeConnection(owns ? "Connected" : "Observing — Take Control to type")
                    if owns, !holdsResizes { requestResize() }
                }
            case .failure(let message):
                retryConnection("Connection error — \(message)", transportFailed: false)
                return
            case .attached:
                break
            case .snapshot(let bytes):
                guard restoreTerminal(from: bytes) else {
                    retryConnection("Connection error — invalid terminal snapshot; retrying", transportFailed: false)
                    return
                }
                restoredConnection = true
                reconnectDelay = 300_000_000
                handshakeTask?.cancel()
                handshakeTask = nil
                describeConnection(observing ? "Observing — Take Control to type" : "Connected")
                setFocused(window?.isKeyWindow == true && window?.firstResponder === self)
                if !observing, !holdsResizes { requestResize() }
            case .output(let bytes):
                showCursor()
                if Self.perf, let sent = inputSentAt {
                    inputSentAt = nil
                    perfLog("echo after \(Int(Date().timeIntervalSince(sent) * 1000)) ms (\(bytes.count) bytes)")
                }
                bytes.withUnsafeBytes { terminal?.write($0) }
            case .resized(let size):
                if Self.perf { perfLog("resized \(size.cols)x\(size.rows)") }
                terminal?.resize(size)
                predictor?.reset()
                forceRender = true
            case .exited(let code):
                guard code >= 0 else {
                    retryConnection("Connection error — pane is unavailable; retrying")
                    return
                }
                handshakeTask?.cancel()
                handshakeTask = nil
                describeConnection(code == 0 ? "Ended" : "Ended — exit status \(code)")
                wantsConnection = false
                reconnectTask?.cancel()
                setFocused(false)
                connection = nil
                onEnd?()
                return
            case .disconnected:
                retryConnection("Connection lost — retrying")
                return
            }
        }
        if let terminal { predictor?.reconcile(with: terminal) }
        pushOverlay()
        updateComposition()
        needsRender = true
    }

    /// Installs one complete server snapshot and resets references into the
    /// old grid. Invalid snapshots leave the current mirror untouched.
    @discardableResult func restoreTerminal(from bytes: [UInt8]) -> Bool {
        guard let restored = VTTerminal(snapshot: bytes) else { return false }
        if let terminal { _ = keyboard.releaseAll(terminal: terminal) }
        selection = nil
        terminal = restored
        renderer?.bind(to: restored)
        restored.onClipboardWrite = { text in
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            }
        }
        applyTerminalConfiguration()
        selection = TerminalSelection(terminal: restored)
        selectingWithMouse = false
        pressedButtons = 0
        unmarkText()
        predictor?.reset()
        showCursor()
        // Only the first blank snapshot gets this bounded grace period;
        // reconnects never suppress the cursor, even on a blank screen.
        if !hasRestored, Self.isBlank(restored) { suppressCursorBriefly() }
        if !hasRestored, endpoint == .local { Launch.noteFirstPane() }
        hasRestored = true
        forceRender = true
        needsRender = true
        return true
    }

    /// A blank viewport at home is a possible shell-startup screen. It is only
    /// a hint, so cursor suppression always has a short independent deadline.
    private static func isBlank(_ terminal: VTTerminal) -> Bool {
        let cursor = terminal.cursor
        guard cursor.x == 0, cursor.y == 0 else { return false }
        return (0..<terminal.size.rows).allSatisfy { row in
            terminal.viewportRow(row).allSatisfy { $0.isEmpty || $0 == " " }
        }
    }

    /// Hides the initial cursor until output/input or a deadline measured from
    /// this call, including when the task first runs after a busy main turn.
    private func suppressCursorBriefly() {
        cursorSuppressed = true
        renderer?.hidesCursor = true
        let deadline = ContinuousClock.now + .nanoseconds(Int64(Self.cursorGrace))
        suppression = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.showCursor()
        }
    }

    private func showCursor() {
        suppression?.cancel()
        suppression = nil
        guard cursorSuppressed else { return }
        cursorSuppressed = false
        renderer?.hidesCursor = false
        forceRender = true
        needsRender = true
    }

    /// A foreground-program change invalidates the predictor's learned echo.
    func setProgram(_ program: String) {
        guard predictor?.program != program else { return }
        predictor?.setProgram(program)
        pushOverlay()
    }

    /// Only changed predictions invalidate a frame. Input may present at once;
    /// output and timer updates share their caller's single presentation.
    private func pushOverlay(immediate: Bool = false) {
        guard let predictor else { return }
        guard renderer.overlay != predictor.overlay else { return }
        renderer.overlay = predictor.overlay
        needsRender = true
        if immediate, focused, window?.occlusionState.contains(.visible) == true { renderNow(inTransaction: false) }
    }

    /// Composition is a local drawing overlay; only committed text goes to
    /// the session. Geometry follows the current font, cursor and pane size.
    private func updateComposition() {
        guard marked.length > 0 else { composition.clear(); return }
        guard focused, let terminal else { composition.isHidden = true; return }
        let cell = NSSize(width: CGFloat(metrics.cellWidth) / scale, height: CGFloat(metrics.cellHeight) / scale)
        let grid = terminal.size
        let size = NSSize(width: CGFloat(grid.cols) * cell.width, height: CGFloat(grid.rows) * cell.height)
        composition.frame = NSRect(origin: NSPoint(x: padding, y: padding), size: size)
        let cursor = terminal.cursor
        let font = NSFont(descriptor: (metrics.regular as NSFont).fontDescriptor, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        func color(_ rgb: GhosttyColorRgb) -> NSColor {
            NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
        }
        composition.update(marked, selected: markedSelection, font: font, cell: cell, grid: size,
                           cursor: NSPoint(x: Int(cursor.x), y: Int(cursor.y)),
                           foreground: color(Theme.current.foreground), background: color(Theme.current.background))
    }

    // MARK: Drawing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if let commandKeyUpMonitor { NSEvent.removeMonitor(commandKeyUpMonitor) }
        commandKeyUpMonitor = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            setFocused(false)
            return
        }
        // A pane that went quiet while covered must draw when uncovered.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.displayLink?.isPaused = false } }
        // AppKit omits Command-key releases from its responder dispatch.
        // Only forward a release for a press this pane actually encoded.
        commandKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.window?.firstResponder === self,
                  event.window === self.window, event.modifierFlags.contains(.command),
                  self.keyboard.isHeld(event.keyCode) else { return event }
            self.keyUp(with: event)
            return nil
        }
        updateMetrics()
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetrics()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Rebuilds the font metrics and glyph atlas only when the size or
    /// backing scale changed (or `force`, when the family may have), so moving
    /// the view between windows and tabs does not re-rasterize every glyph.
    private func updateMetrics(force: Bool = false) {
        let key = (size: fontSize, scale: scale)
        if force || key != metricsKey {
            metrics = FontMetrics(size: key.size, scale: key.scale)
            metricsKey = key
            renderer?.setMetrics(metrics)
            metalLayer.contentsScale = scale
        }
        layoutGrid()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutGrid()
    }

    private func layoutGrid() {
        let drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let resized = drawableSize != metalLayer.drawableSize
        metalLayer.drawableSize = drawableSize
        let pad = Float((padding * scale).rounded())
        renderer?.padding = [pad, pad]
        updateComposition()
        forceRender = true
        needsRender = true
        if !holdsResizes { requestResize() }
        if resized, drawableSize.width > 0, drawableSize.height > 0 { renderNow(inTransaction: true) }
    }

    /// Sends the settled grid if it differs from what the session was last
    /// asked for. An unfittable view sends nothing rather than a 2x1 placeholder.
    private func requestResize() {
        guard !observing, connection?.allowsInput == true, restoredConnection, let size = fittedGrid() else { return }
        if Self.perf { perfLog("grid \(size.cols)x\(size.rows) bounds \(bounds.size) requested \(String(describing: requested)) connected \(connection != nil)") }
        if connection != nil, size != requested {
            requested = size
            connection?.send(resize: size)
            if Self.perf { perfLog("sent resize \(size.cols)x\(size.rows)") }
        }
    }

    /// Draws a frame at once rather than on the next display tick; within
    /// the transaction, it appears together with the view's new frame, so a
    /// pane that was just made or resized never flashes its frost or its
    /// old frame stretched.
    private func renderNow(inTransaction: Bool) {
        guard let renderer else { return }
        metalLayer.presentsWithTransaction = inTransaction
        defer { metalLayer.presentsWithTransaction = false }
        let presented = if let terminal {
            renderer.render(terminal, into: metalLayer, force: forceRender)
        } else {
            renderer.clear(into: metalLayer)
        }
        // A missed present keeps the flags, so the next tick tries again.
        guard presented else { return }
        needsRender = false
        forceRender = false
    }

    /// The grid this view fits, for sizing new panes like it.
    var currentGridSize: GridSize { gridSize() }

    /// The grid for this view, clamped to at least 2x1 cells.
    private func gridSize() -> GridSize {
        fittedGrid() ?? GridSize(cols: 2, rows: 1, cellWidth: UInt32(metrics.cellWidth),
                                 cellHeight: UInt32(metrics.cellHeight))
    }

    /// The grid this view really fits, nil until it is in a window and big
    /// enough for one; only such a grid may be sent to the session.
    private func fittedGrid() -> GridSize? {
        guard window != nil else { return nil }
        return Self.fit(points: bounds.size, scale: scale, padding: padding,
                        cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight)
    }

    /// The cells that fit in `points` inside `padding` on every side, or nil
    /// if not even 2x1 do (the least a terminal can be).
    static func fit(points: CGSize, scale: CGFloat, padding: CGFloat, cellWidth: Int, cellHeight: Int) -> GridSize? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let pad = (padding * scale).rounded() * 2
        let w = Int(max(0, points.width * scale - pad)), h = Int(max(0, points.height * scale - pad))
        let cols = w / cellWidth, rows = h / cellHeight
        guard cols >= 2, rows >= 1, cols <= Int(UInt16.max), rows <= Int(UInt16.max) else { return nil }
        return GridSize(cols: UInt16(cols), rows: UInt16(rows),
                        cellWidth: UInt32(cellWidth), cellHeight: UInt32(cellHeight))
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if selection?.autoscrolling == true, now - lastSelectionScroll >= 1.0 / 30 {
            lastSelectionScroll = now
            if selection?.autoscroll(geometry: selectionGeometry) == true {
                accessibilityChanged()
                needsRender = true
            }
        }
        if predictor?.isActive == true {
            predictor?.expire()
            pushOverlay()
        }
        // Nothing pending, or nobody can see it: stop ticking until output,
        // input, a gesture or the window being uncovered asks again.
        guard selection?.autoscrolling == true || predictor?.isActive == true
                || (needsRender && window?.occlusionState.contains(.visible) == true) else {
            displayLink?.isPaused = true
            return
        }
        // Nothing to show to a view with no size.
        guard needsRender, metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else { return }
        let began = Date()
        let forced = forceRender
        renderNow(inTransaction: false)
        if Self.perf {
            let ms = Date().timeIntervalSince(began) * 1000
            if ms > 1 { perfLog("render \(String(format: "%.1f", ms)) ms force=\(forced)") }
        }
    }

    override func becomeFirstResponder() -> Bool {
        setFocused(true)
        onFocus?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        setFocused(false)
        return true
    }

    func setFocused(_ focused: Bool) {
        self.focused = focused
        if !focused {
            if let terminal { sendInput(keyboard.releaseAll(terminal: terminal)) }
            selection?.cancel()
            selectingWithMouse = false
            pressedButtons = 0
            if hasMarkedText() {
                inputContext?.discardMarkedText()
                unmarkText()
            }
        }
        renderer?.focused = focused
        updateComposition()
        forceRender = true
        needsRender = true
        if let terminal, terminal.mode(1004) {
            connection?.send(input: Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8))
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard terminal != nil, !observing else { return }
        showCursor()
        let wasComposing = hasMarkedText()
        if !wasComposing, TerminalKeyboard.usesOptionAsAlt(event) {
            encode(event, action: event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS, text: event.keyText)
            return
        }
        inserted = []
        interpretKeyEvents([event])
        let texts = inserted ?? []
        inserted = nil
        if let committed = Self.compositionCommits(texts, before: wasComposing, after: hasMarkedText()) {
            // A partial commit can leave another marked segment active.
            for text in committed { send(text: text) }
            if !hasMarkedText(), !committed.isEmpty, Self.replaysCompositionKey(event) {
                encode(event, action: event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS, text: nil)
            }
            return
        }
        let printable = texts.filter { !$0.isControl }
        if printable.isEmpty {
            encode(event, action: event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS, text: event.keyText)
        } else {
            for t in printable {
                encode(event, action: event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS, text: t)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard terminal != nil else { return }
        encode(event, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let terminal, !hasMarkedText() else { return }
        sendInput(keyboard.flagsChanged(event, terminal: terminal))
    }

    /// Nil means ordinary typing; an empty list means the IME consumed the key.
    /// Commits are kept even when the input method starts a new marked segment.
    static func compositionCommits(_ texts: [String], before: Bool, after: Bool) -> [String]? {
        guard before || after else { return nil }
        return texts.filter { !$0.isEmpty && !$0.isControl }
    }

    /// Match Ghostty's IME navigation behavior without replaying confirmation
    /// Enter or the plain Left that Korean composition already handles.
    private static func replaysCompositionKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124, 125, 126: true
        case 123: !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: false
        }
    }

    /// Empty encodings are local actions and never become protocol frames.
    private func sendInput(_ bytes: [UInt8]) {
        if !bytes.isEmpty { connection?.send(input: bytes) }
    }

    /// Give configured menu shortcuts priority, then route Control and Command
    /// keys through terminal handling rather than AppKit text commands.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.control) || mods.contains(.command) else { return false }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        keyDown(with: event)
        return true
    }

    private func encode(_ event: NSEvent, action: GhosttyKeyAction, text: String?) {
        guard let terminal else { return }
        let bytes = keyboard.encode(event, action: action, text: text, terminal: terminal)
        guard !bytes.isEmpty else { return }
        if action != GHOSTTY_KEY_ACTION_RELEASE {
            terminal.clearSelection()
            scrollToBottom()
        }
        if Self.perf, action != GHOSTTY_KEY_ACTION_RELEASE { inputSentAt = Date() }
        connection?.send(input: bytes)
        if action != GHOSTTY_KEY_ACTION_RELEASE { predict(event, text: text) }
    }

    /// Tells the predictor what was just sent.
    private func predict(_ event: NSEvent, text: String?) {
        guard canControl, predictor != nil, let terminal else { return }
        let mods = event.modifierFlags.intersection([.control, .command, .option])
        switch event.keyCode {
        case 0x33 where mods.isEmpty: predictor?.backspace(in: terminal)
        case 0x24, 0x4C: predictor?.entered()
        default:
            if let text, mods.isEmpty { predictor?.typed(text, in: terminal) } else { predictor?.other() }
        }
        pushOverlay(immediate: true)
    }

    private func send(text: String) {
        guard !text.isEmpty else { return }
        showCursor()
        terminal?.clearSelection()
        scrollToBottom()
        connection?.send(input: Array(text.utf8))
        predictor?.other()
        pushOverlay()
    }

    private func perfLog(_ message: String) {
        FileHandle.standardError.write(Data("[perf] \(message)\n".utf8))
    }

    private func scrollToBottom() {
        terminal?.scrollToBottom()
        accessibilityChanged()
        needsRender = true
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var m: Int32 = 0
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS_LOCK }
        return GhosttyMods(m)
    }

    // MARK: Paste

    @objc func paste(_ sender: Any?) {
        guard let text = Self.pasteText(on: .general) else { return }
        paste(text)
    }

    /// What a pasteboard holds, for pasting: copied files as their paths,
    /// quoted for the shell, else its text. Every item is looked at, and
    /// text under any plain-text type counts: a launcher such as Raycast
    /// puts the text in a later item beside the other types it recorded,
    /// and some apps name a plain-text type other than the standard one.
    static func pasteText(on board: NSPasteboard) -> String? {
        let items = board.pasteboardItems ?? []
        let paths = items.compactMap { item -> String? in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL else { return nil }
            return shellQuoted(url.path)
        }
        if !paths.isEmpty { return paths.joined(separator: " ") }
        let texts = items.compactMap { item -> String? in
            if let s = item.string(forType: .string) { return s }
            let plain = item.types.first { UTType($0.rawValue)?.conforms(to: .plainText) == true }
            return plain.flatMap { item.string(forType: $0) }
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    /// Sends text as a paste: bracketed when the program asked for it.
    private func paste(_ text: String) {
        guard let terminal, !text.isEmpty else { return }
        showCursor()
        let bytes = Self.pasteBytes(text, bracketed: terminal.mode(2004))
        guard !bytes.isEmpty else { return }
        terminal.clearSelection()
        scrollToBottom()
        sendInput(bytes)
        predictor?.other()
        pushOverlay()
    }

    /// Clipboard and dropped text share the engine's paste sanitization and
    /// newline rules; bracketed mode is read fresh for every paste.
    static func pasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        var data = Array(text.utf8CString.dropLast())
        var out = [CChar](repeating: 0, count: data.count * 2 + 16)
        var written = 0
        var r = ghostty_paste_encode(&data, data.count, bracketed, &out, out.count, &written)
        if r == GHOSTTY_OUT_OF_SPACE {
            out = [CChar](repeating: 0, count: written)
            r = ghostty_paste_encode(&data, data.count, bracketed, &out, out.count, &written)
        }
        guard r == GHOSTTY_SUCCESS else { return [] }
        return out[0..<written].map { UInt8(bitPattern: $0) }
    }

    // MARK: Drag and drop

    /// Paste one shell-quoted filesystem path. In a remote pane a file URL is
    /// a path on that remote host; this never uploads or resolves local files.
    func insertPath(_ url: URL) {
        guard let path = Self.shellPath(url) else { return }
        paste(Self.shellQuoted(path) + " ")
    }

    /// Run cd in this pane's shell. Remote callers must supply a path on the
    /// endpoint, not a directory obtained from a local file picker. Bracketed
    /// paste ends before Enter, so shells execute the command in either mode.
    func goToDirectory(_ url: URL) {
        guard let path = Self.shellPath(url), terminal != nil else { return }
        paste("cd -- " + Self.shellQuoted(path))
        sendInput([0x0d])
    }

    /// Accept explicit absolute paths only. Control bytes would be rewritten
    /// by paste sanitization and could name a different directory.
    static func shellPath(_ url: URL) -> String? {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        let host = url.host ?? ""
        guard host.isEmpty || host == "localhost" else { return nil }
        return url.path
    }

    /// Navigate semantic shell prompts; no shell integration means no movement.
    @discardableResult func scrollPrompt(previous: Bool) -> Bool {
        guard terminal?.scrollPrompt(previous: previous) == true else { return false }
        accessibilityChanged()
        forceRender = true
        needsRender = true
        return true
    }

    /// Files dropped on the pane are typed as paths, quoted for the shell
    /// and followed by a space, as Terminal does; dropped text is pasted.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.string) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        guard var text = Self.pasteText(on: board) else { return false }
        if (board.types ?? []).contains(.fileURL) { text += " " }
        window?.makeFirstResponder(self)
        paste(text)
        return true
    }

    /// A path as a shell word: as is when it is only safe characters, else
    /// in single quotes.
    static func shellQuoted(_ path: String) -> String {
        let safe = path.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-+:@%=,~".unicodeScalars.contains($0) }
        if safe, !path.isEmpty { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Mouse

    override func scrollWheel(with event: NSEvent) {
        guard let terminal else { return }
        let cellPoints = CGFloat(metrics.cellHeight) / scale
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dy *= cellPoints }
        scrollRemainder += dy
        let rows = Int(scrollRemainder / cellPoints)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows) * cellPoints

        // A program that tracks the mouse gets wheel buttons.
        let button = rows > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
        var wheel = [UInt8]()
        for _ in 0..<abs(rows) {
            wheel += encodeMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: button, event: event)
        }
        if !wheel.isEmpty {
            connection?.send(input: wheel)
            return
        }
        // Full-screen programs without mouse tracking get arrow keys, as
        // xterm's alternate scroll mode does.
        if terminal.isAlternateScreen {
            let app = terminal.mode(1)
            let key = rows > 0 ? (app ? "\u{1b}OA" : "\u{1b}[A") : (app ? "\u{1b}OB" : "\u{1b}[B")
            connection?.send(input: Array(String(repeating: key, count: abs(rows)).utf8))
            return
        }
        terminal.scroll(rows: -rows)
        accessibilityChanged()
        needsRender = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // ⌘-click opens a URL under the pointer, as other terminals do.
        if event.modifierFlags.contains(.command), openURL(at: event) { return }
        // Shift always reserves a local selection, even inside mouse-aware
        // programs. Keep that routing until release if Shift changes later.
        selectingWithMouse = event.modifierFlags.contains(.shift)
        if !selectingWithMouse, mouseButton(event, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT) { return }
        selectingWithMouse = true
        selection?.press(at: selectionPoint(event), geometry: selectionGeometry,
                         time: event.timestamp, repeatInterval: NSEvent.doubleClickInterval)
        accessibilityChanged()
        needsRender = true
    }
    override func mouseUp(with event: NSEvent) {
        if selectingWithMouse {
            selection?.release(at: selectionPoint(event), geometry: selectionGeometry)
            selectingWithMouse = false
            pressedButtons = 0
            accessibilityChanged()
            needsRender = true
        } else {
            mouseButton(event, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT)
        }
    }
    override func rightMouseDown(with event: NSEvent) { _ = mouseButton(event, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { _ = mouseButton(event, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_RIGHT) }
    override func otherMouseDown(with event: NSEvent) { _ = mouseButton(event, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { _ = mouseButton(event, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_MIDDLE) }
    override func mouseDragged(with event: NSEvent) {
        guard selectingWithMouse else { _ = mouseMotion(event); return }
        selection?.drag(at: selectionPoint(event), geometry: selectionGeometry)
        accessibilityChanged()
        needsRender = true
    }
    override func rightMouseDragged(with event: NSEvent) { _ = mouseMotion(event) }
    override func otherMouseDragged(with event: NSEvent) { _ = mouseMotion(event) }
    override func mouseMoved(with event: NSEvent) {
        toolTip = link(at: event)?.absoluteString
        _ = mouseMotion(event)
    }
    override func mouseExited(with event: NSEvent) { toolTip = nil }

    private var selectionGeometry: TerminalSelection.Geometry {
        .init(size: CGSize(width: bounds.width * scale, height: bounds.height * scale),
              cell: CGSize(width: metrics.cellWidth, height: metrics.cellHeight), padding: padding * scale)
    }

    private func selectionPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    /// The viewport cell under a mouse event, clamped to the grid.
    private func cell(at event: NSEvent) -> (col: UInt16, row: UInt16) {
        let p = convert(event.locationInWindow, from: nil)  // flipped: y down from top
        let cw = CGFloat(metrics.cellWidth) / scale, ch = CGFloat(metrics.cellHeight) / scale
        let col = Int(((p.x - padding) / cw).rounded(.down))
        let row = Int(((p.y - padding) / ch).rounded(.down))
        let size = terminal?.size ?? (cols: 2, rows: 1)
        return (UInt16(min(max(col, 0), Int(size.cols) - 1)), UInt16(min(max(row, 0), Int(size.rows) - 1)))
    }

    // MARK: Selection and copy

    @objc func copy(_ sender: Any?) {
        guard let text = terminal?.selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        terminal?.selectAll()
        accessibilityChanged()
        needsRender = true
    }

    /// Opens a URL under the pointer in the default browser, if there is one.
    private func openURL(at event: NSEvent) -> Bool {
        guard let url = link(at: event) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Hover and activation share a UTF-16 hit test and scheme allowlist.
    private func link(at event: NSEvent) -> URL? {
        guard let terminal else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let grid = NSRect(x: padding, y: padding,
                          width: CGFloat(terminal.size.cols) * CGFloat(metrics.cellWidth) / scale,
                          height: CGFloat(terminal.size.rows) * CGFloat(metrics.cellHeight) / scale)
        guard bounds.contains(local), grid.contains(local) else { return nil }
        let (col, row) = cell(at: event)
        // OSC 8 labels can differ entirely from their destination. Inspect the
        // engine's target first, and apply the same safe schemes as plain URLs.
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: col, y: UInt32(row))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        if ghostty_terminal_grid_ref(terminal.raw, point, &ref) == GHOSTTY_SUCCESS {
            var bytes = [UInt8](repeating: 0, count: 8192), length = 0
            let result = ghostty_grid_ref_hyperlink_uri(&ref, &bytes, bytes.count, &length)
            if result == GHOSTTY_OUT_OF_SPACE { return nil }
            if result == GHOSTTY_SUCCESS, length > 0 {
                guard let url = URL(string: String(decoding: bytes.prefix(length), as: UTF8.self)),
                      let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
                return url
            }
        }
        let cells = terminal.viewportRow(row)
        let offset = cells.prefix(Int(col)).reduce(0) { $0 + ($1 as NSString).length }
        return Self.url(in: cells.joined(), at: offset)
    }

    /// The link in `line` that covers UTF-16 `offset`, if it is a web or
    /// mail URL (not an arbitrary scheme).
    static func url(in line: String, at offset: Int) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let full = NSRange(location: 0, length: (line as NSString).length)
        for m in detector.matches(in: line, range: full) where NSLocationInRange(offset, m.range) {
            if let url = m.url, let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) { return url }
        }
        return nil
    }

    // MARK: Find

    @objc func performFind(_ sender: Any?) {
        if findBar == nil { makeFindBar() }
        findBar?.isHidden = false
        window?.makeFirstResponder(findField)
        runFind()
    }

    /// Closes the find bar and clears the match highlight.
    func endFind() {
        findBar?.isHidden = true
        terminal?.searchEnd()
        accessibilityChanged()
        forceRender = true
        needsRender = true
        if let window, let findField, window.firstResponder === findField.currentEditor() {
            window.makeFirstResponder(self)
        }
    }

    private func makeFindBar() {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField()
        field.placeholderString = "Find"
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(field)
        bar.addSubview(label)
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            field.topAnchor.constraint(equalTo: bar.topAnchor, constant: 7),
            field.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -7),
            field.widthAnchor.constraint(equalToConstant: 180),
            label.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
        ])
        findBar = bar
        findField = field
        findLabel = label
    }

    /// Runs the current query and jumps to the first match.
    private func runFind() {
        let query = findField?.stringValue ?? ""
        let total = terminal?.searchStart(query) ?? 0
        if total > 0, let r = terminal?.searchSelect(next: true) {
            findLabel?.stringValue = "\(r.index)/\(r.total)"
        } else {
            findLabel?.stringValue = query.isEmpty ? "" : "none"
        }
        accessibilityChanged()
        forceRender = true
        needsRender = true
    }

    private func findStep(next: Bool) {
        guard let r = terminal?.searchSelect(next: next) else { return }
        findLabel?.stringValue = "\(r.index)/\(r.total)"
        accessibilityChanged()
        forceRender = true
        needsRender = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// Encodes and sends the event to a program tracking the mouse; returns
    /// whether it did, so the caller can fall back to selection.
    @discardableResult
    private func mouseButton(_ event: NSEvent, _ action: GhosttyMouseAction, _ button: GhosttyMouseButton) -> Bool {
        pressedButtons += action == GHOSTTY_MOUSE_ACTION_PRESS ? 1 : -1
        pressedButtons = max(0, pressedButtons)
        let bytes = encodeMouse(action, button: button, event: event)
        guard !bytes.isEmpty else { return false }
        connection?.send(input: bytes)
        return true
    }

    @discardableResult
    private func mouseMotion(_ event: NSEvent) -> Bool {
        let bytes = encodeMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: nil, event: event)
        guard !bytes.isEmpty else { return false }
        connection?.send(input: bytes)
        return true
    }

    /// The bytes reporting a mouse event to the program; empty when it does
    /// not track the mouse.
    private func encodeMouse(_ action: GhosttyMouseAction, button: GhosttyMouseButton?, event: NSEvent) -> [UInt8] {
        guard let terminal, let mouseEncoder, let mouseEvent else { return [] }
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal.raw)
        let pad = UInt32((padding * scale).rounded())
        var size = GhosttyMouseEncoderSize(
            size: MemoryLayout<GhosttyMouseEncoderSize>.size,
            screen_width: UInt32(bounds.width * scale), screen_height: UInt32(bounds.height * scale),
            cell_width: UInt32(metrics.cellWidth), cell_height: UInt32(metrics.cellHeight),
            padding_top: pad, padding_bottom: pad, padding_right: pad, padding_left: pad)
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var any = pressedButtons > 0
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any)
        ghostty_mouse_event_set_action(mouseEvent, action)
        if let button { ghostty_mouse_event_set_button(mouseEvent, button) } else { ghostty_mouse_event_clear_button(mouseEvent) }
        ghostty_mouse_event_set_mods(mouseEvent, Self.mods(event.modifierFlags))
        let p = convert(event.locationInWindow, from: nil)
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(p.x * scale), y: Float(p.y * scale)))
        var buf = [CChar](repeating: 0, count: 64)
        var len = 0
        guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &buf, buf.count, &len) == GHOSTTY_SUCCESS else { return [] }
        return buf[0..<len].map { UInt8(bitPattern: $0) }
    }

    // MARK: Accessibility

    /// Read-only terminal contents, with native AX text navigation. AX and IME
    /// ranges deliberately use different documents: shell output versus marked
    /// composition. Reading AX must never commit or replace terminal input.
    private var accessibleText: TerminalAccessibilityText {
        accessibilityObserved = true
        if accessibilityDocument == nil { accessibilityDocument = TerminalAccessibilityText(terminal) }
        return accessibilityDocument!
    }

    /// Output and viewport/selection mutations coalesce at four batches per
    /// second. Notifications carry no text; only an AX query formats history.
    private func accessibilityChanged() {
        accessibilityDocument = nil
        guard accessibilityObserved, accessibilityNotificationTask == nil else { return }
        accessibilityNotificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.accessibilityNotificationTask = nil
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityHelp() -> String? { connectionDescription }
    override func accessibilityValue() -> Any? { accessibleText.text as String }
    override func accessibilityNumberOfCharacters() -> Int { accessibleText.text.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { accessibleText.visible }
    override func accessibilitySelectedText() -> String? { accessibleText.selectedText }
    override func accessibilitySelectedTextRange() -> NSRange { accessibleText.selectedRange }
    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        let range = accessibleText.selectedRange
        return range.location == NSNotFound ? [] : [NSValue(range: range)]
    }
    override func accessibilityInsertionPointLineNumber() -> Int { accessibleText.cursorLine }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeFirstResponder(self) }
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if [#selector(setAccessibilityValue(_:)), #selector(setAccessibilitySelectedText(_:)),
            #selector(setAccessibilitySelectedTextRange(_:)), #selector(setAccessibilitySelectedTextRanges(_:))].contains(selector) {
            return false
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func accessibilityString(for range: NSRange) -> String? {
        let document = accessibleText
        return document.contains(range) ? document.text.substring(with: range) : nil
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }
    override func accessibilityLine(for index: Int) -> Int { accessibleText.line(for: index) }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        let document = accessibleText
        guard document.lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        return document.lines[line]
    }
    override func accessibilityRange(for index: Int) -> NSRange {
        let text = accessibleText.text
        guard index >= 0, index <= text.length else { return NSRange(location: NSNotFound, length: 0) }
        return index == text.length ? NSRange(location: index, length: 0) : text.rangeOfComposedCharacterSequence(at: index)
    }
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window, let terminal else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let x = (local.x - padding) * scale / CGFloat(metrics.cellWidth)
        let y = (local.y - padding) * scale / CGFloat(metrics.cellHeight)
        guard x.isFinite, y.isFinite, x >= 0, x < CGFloat(terminal.size.cols),
              y >= 0, y < CGFloat(terminal.size.rows) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let document = accessibleText
        return document.range(row: Int(y) + document.viewportRow, column: Int(x), terminal: terminal)
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let document = accessibleText
        guard document.contains(range), let window, let terminal else { return .zero }
        let startLine = document.line(for: range.location)
        let endLine = document.line(for: max(range.location, NSMaxRange(range) - 1))
        let firstLine = max(startLine, document.viewportRow)
        let lastLine = min(endLine, document.viewportRow + Int(terminal.size.rows) - 1)
        guard firstLine <= lastLine else { return .zero }
        let cell = NSSize(width: CGFloat(metrics.cellWidth) / scale, height: CGFloat(metrics.cellHeight) / scale)
        let singleLine = startLine == endLine
        let firstColumn = singleLine ? document.column(for: range.location, row: startLine, terminal: terminal) : 0
        let lastColumn = singleLine ? document.column(for: NSMaxRange(range), row: endLine, terminal: terminal, trailing: true) : Int(terminal.size.cols)
        let rect = NSRect(x: padding + CGFloat(firstColumn) * cell.width,
                          y: padding + CGFloat(firstLine - document.viewportRow) * cell.height,
                          width: CGFloat(max(1, lastColumn - firstColumn)) * cell.width,
                          height: CGFloat(lastLine - firstLine + 1) * cell.height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        updateComposition()
        if inserted != nil {
            inserted?.append(text)
        } else {
            // From outside a key press: the emoji picker, dictation.
            send(text: text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString { marked = NSMutableAttributedString(attributedString: s) }
        else if let s = string as? String { marked = NSMutableAttributedString(string: s) }
        markedSelection = CompositionView.clamp(selectedRange, length: marked.length)
        scrollToBottom()
        updateComposition()
    }

    func unmarkText() {
        marked = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        updateComposition()
    }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText() else { return nil }
        let bounded = CompositionView.clamp(range, length: marked.length)
        actualRange?.pointee = bounded
        return marked.attributedSubstring(from: bounded)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {}

    /// Where the input method puts its candidates: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let terminal, let window else { return .zero }
        if hasMarkedText() {
            let bounded = CompositionView.clamp(range, length: marked.length)
            actualRange?.pointee = bounded
            let rect = composition.rect(for: bounded, cellHeight: CGFloat(metrics.cellHeight) / scale)
            return window.convertToScreen(composition.convert(rect, to: nil))
        }
        let (x, y) = terminal.cursor
        let cw = CGFloat(metrics.cellWidth) / scale, ch = CGFloat(metrics.cellHeight) / scale
        let local = NSRect(x: padding + CGFloat(x) * cw, y: padding + CGFloat(y) * ch, width: cw, height: ch)
        return window.convertToScreen(convert(local, to: nil))
    }
}

private extension String {
    /// A lone C0 control or DEL, which AppKit sometimes inserts for Control
    /// combinations; the key encoder produces those itself.
    var isControl: Bool {
        guard unicodeScalars.count == 1, let s = unicodeScalars.first else { return false }
        return s.value < 0x20 || s.value == 0x7f
    }
}

extension NSEvent {
    /// The text a key produces for the encoder: what it types without
    /// Control, and nothing for function keys, whose characters are in the
    /// private use area.
    var keyText: String? {
        guard var chars = characters, let first = chars.unicodeScalars.first else { return nil }
        if first.value < 0x20, let plain = characters(byApplyingModifiers: modifierFlags.subtracting(.control)) {
            chars = plain
        }
        guard let s = chars.unicodeScalars.first, !(0xF700...0xF8FF).contains(s.value), !chars.isControl else { return nil }
        return chars
    }

    var unshiftedCodepoint: UInt32 {
        guard let s = characters(byApplyingModifiers: [])?.unicodeScalars.first, !(0xF700...0xF8FF).contains(s.value) else { return 0 }
        return s.value
    }
}

extension TerminalView: NSTextFieldDelegate {
    /// Live search as the query changes.
    func controlTextDidChange(_ obj: Notification) { runFind() }

    /// Return jumps to the next match (Shift-Return the previous); Escape
    /// closes the find bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            findStep(next: !NSEvent.modifierFlags.contains(.shift))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endFind()
            return true
        default:
            return false
        }
    }
}
