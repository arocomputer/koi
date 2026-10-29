import AppKit
import SwiftUI
import QuartzCore

extension NSView {
    /// Pointer monitors must respect clipping even when a covered view stays drawn.
    func koiExposes(_ windowPoint: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, visibleRect.contains(convert(windowPoint, from: nil)) else { return false }
        var ancestor: NSView? = self
        while let view = ancestor {
            if let mask = view.layer?.mask as? CAShapeLayer, let path = mask.path {
                let point = view.convert(windowPoint, from: nil)
                if !path.contains(point, using: mask.fillRule == .evenOdd ? .evenOdd : .winding) { return false }
            }
            ancestor = view.superview
        }
        return true
    }
}

/// The window's actual chrome constraints, shared with offscreen geometry tests.
/// The sidebar reserves its own header; these controls belong to the window.
@MainActor
struct ChromeLayout {
    static let minimumSidebarWidth: CGFloat = 220
    static let maximumSidebarWidth: CGFloat = 360
    static let minimumContentWidth: CGFloat = 240

    /// The effective width after applying the window-space clamp.
    let sidebarWidth: NSLayoutConstraint
    /// Constraint layout can synchronously deliver another window notification.
    var isLayingOut = false
    private let root: NSView
    private let cardLeading: NSLayoutConstraint
    private let cardTrailing: NSLayoutConstraint
    private let cardTop: NSLayoutConstraint
    private let sidebarLeft: NSLayoutConstraint
    private let sidebarRight: NSLayoutConstraint
    private let toggleLeft: NSLayoutConstraint
    private let toggleRight: NSLayoutConstraint
    private let resizeHandle: NSView?
    private let resizeLeft: NSLayoutConstraint?
    private let resizeRight: NSLayoutConstraint?

    init(root: NSView, card: NSView, sidebar: NSView, toggle: NSView, actions: NSView,
         resizeHandle: NSView? = nil) {
        self.root = root
        self.resizeHandle = resizeHandle
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: AppDelegate.sidebarWidth)
        cardLeading = card.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        cardTrailing = card.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        cardTop = card.topAnchor.constraint(equalTo: root.topAnchor)
        sidebarLeft = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        sidebarRight = sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        toggleLeft = toggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 82)
        toggleRight = toggle.leadingAnchor.constraint(equalTo: root.trailingAnchor)
        resizeLeft = resizeHandle?.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor)
        resizeRight = resizeHandle?.centerXAnchor.constraint(equalTo: sidebar.leadingAnchor)
        NSLayoutConstraint.activate([
            cardLeading, cardTrailing, cardTop,
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -AppDelegate.inset),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,
            toggle.centerYAnchor.constraint(equalTo: root.topAnchor, constant: AppDelegate.topRow / 2),
            actions.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: root.topAnchor, constant: AppDelegate.topRow / 2),
        ])
        if let resizeHandle {
            NSLayoutConstraint.activate([
                resizeHandle.topAnchor.constraint(equalTo: root.topAnchor, constant: AppDelegate.topRow),
                resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                resizeHandle.widthAnchor.constraint(equalToConstant: 8),
            ])
        }
    }

    /// Reserve room for visible chrome. Collapsed vertical layouts restore the
    /// terminal's full-window inset; Top always reserves its header.
    func apply(tabs: Config.Tabs, sidebarShown: Bool, width: CGFloat? = nil, progress: CGFloat? = nil) {
        let visible = tabs.isVertical && sidebarShown
        let fraction = tabs.isVertical ? min(1, max(0, progress ?? (sidebarShown ? 1 : 0))) : 0
        let proposed = width ?? sidebarWidth.constant
        let maximum = max(0, min(Self.maximumSidebarWidth,
                                 root.bounds.width - Self.minimumContentWidth - AppDelegate.inset))
        sidebarWidth.constant = min(max(proposed.isFinite ? proposed : AppDelegate.sidebarWidth,
                                        min(Self.minimumSidebarWidth, maximum)), maximum)
        let anchors = tabs.isRight ? [sidebarRight, toggleRight] : [sidebarLeft, toggleLeft]
        if !anchors.allSatisfy(\.isActive) {
            NSLayoutConstraint.deactivate([sidebarLeft, sidebarRight, toggleLeft, toggleRight])
            NSLayoutConstraint.activate(anchors)
        }
        toggleRight.constant = -sidebarWidth.constant + 12
        let rail = (sidebarWidth.constant - AppDelegate.inset) * fraction
        cardLeading.constant = AppDelegate.inset + (tabs.isRight ? 0 : rail)
        cardTrailing.constant = -AppDelegate.inset - (tabs.isRight ? rail : 0)
        cardTop.constant = tabs == .top ? AppDelegate.topRow
            : AppDelegate.inset + (tabs.isRight ? (AppDelegate.topRow - AppDelegate.inset) * fraction : 0)
        if let edge = tabs.isRight ? resizeRight : resizeLeft, !edge.isActive {
            NSLayoutConstraint.deactivate([resizeLeft, resizeRight].compactMap { $0 })
            edge.isActive = true
        }
        resizeHandle?.isHidden = !visible || fraction < 1
    }

    /// Translate a window-coordinate drag to the rail's width at either edge.
    /// Every update starts from mouse-down width, so clamping cannot accumulate drift.
    func resizeSidebar(from width: CGFloat, translation: CGFloat, tabs: Config.Tabs) {
        guard tabs.isVertical else { return }
        apply(tabs: tabs, sidebarShown: true, width: width + (tabs.isRight ? -translation : translation))
    }

    /// Final pane-container dimensions without briefly installing destination
    /// constraints. Sidebar motion can then seat each terminal grid just once.
    func destinationSize(tabs: Config.Tabs, sidebarShown: Bool) -> NSSize {
        let rail = tabs.isVertical && sidebarShown ? sidebarWidth.constant - AppDelegate.inset : 0
        let top = tabs == .top || (tabs.isRight && sidebarShown) ? AppDelegate.topRow : AppDelegate.inset
        return NSSize(width: max(0, root.bounds.width - 2 * AppDelegate.inset - rail),
                      height: max(0, root.bounds.height - top - AppDelegate.inset))
    }
}

/// An invisible inner-edge grip using normal AppKit event dispatch. Window
/// coordinates stay stable as constraints move the grip during the drag.
@MainActor
final class SidebarResizeHandle: NSView {
    var onBegin: (() -> Bool)?
    var onResize: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var startX: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if !isHidden { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    /// Acquire the resize owner before accepting this mouse sequence.
    override func mouseDown(with event: NSEvent) {
        guard startX == nil, !isHiddenOrHasHiddenAncestor, onBegin?() == true else { return }
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX else { return }
        onResize?(event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        guard let startX else { return }
        onResize?(event.locationInWindow.x - startX)
        cancel()
    }

    /// Removing the grip cannot strand its external terminal resize hold.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancel() }
    }

    /// Finish at the current width; duplicate cancellation is harmless.
    func cancel() {
        guard startX != nil else { return }
        startX = nil
        onEnd?()
        NSCursor.arrow.set()
    }
}

/// Construct and lay out the main window, coordinating sidebar motion and chrome coverage.
/// Stored state stays on AppDelegate; lifecycle and action routing call these window operations.
extension AppDelegate {
    /// Clip chrome to its exposed portions without fading or moving its contents.
    @MainActor struct ChromeCoverage {
        let view: NSView
        let mask = CAShapeLayer()
        let originalMask: CALayer?
        let enabled: Bool?

        init(_ view: NSView) {
            self.view = view
            view.wantsLayer = true
            originalMask = view.layer?.mask
            enabled = (view as? NSButton)?.isEnabled
            mask.fillColor = NSColor.black.cgColor
        }

        func restore() {
            if view.layer?.mask === mask { view.layer?.mask = originalMask }
            if let enabled, let button = view as? NSButton, button.isEnabled != enabled { button.isEnabled = enabled }
        }
    }
    /// A weak display-link target lets window teardown release the animation.
    @MainActor private final class SidebarClock: NSObject {
        weak var owner: AppDelegate?
        init(_ owner: AppDelegate) { self.owner = owner }
        @objc func tick() { owner?.tickSidebar(at: CACurrentMediaTime()) }
    }

    /// Cancel pending chrome work and restore native masks before views detach.
    /// Window close and application termination use the same cleanup order.
    func cleanupWindow() {
        card?.onSurfaceLayout = nil
        endSidebarTransition()
        resizeHandle?.cancel()
        coveredChrome.forEach { $0.restore() }
    }

    /// Clamp the live rail to the available content area as the window changes.
    func windowDidResize(_ notification: Notification) {
        guard window != nil, chromeLayout != nil, !chromeLayout.isLayingOut else { return }
        layoutChrome()
        if sidebarTransition != nil {
            // Clamp the rail first, then retarget the live destination once for
            // this window size. Keep the installed fraction and clock continuous.
            card.setLayoutTransitionActive(true, finalSize: chromeLayout.destinationSize(tabs: Config.current.tabs, sidebarShown: sidebarShown))
            card.layoutSubtreeIfNeeded()
        }
    }

    /// Closing the window cancels pending chrome work before its views detach.
    func windowWillClose(_ notification: Notification) {
        closeWindowOwner()
    }

    /// Build and seat the window without presenting it.
    /// Launch and offscreen chrome checks use this same construction path.
    func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // An empty unified toolbar: it draws nothing, but makes the title
        // bar as tall as the top row with the window buttons inset and
        // centered in it, the way AppKit lays them out itself.
        let toolbar = NSToolbar(identifier: "koi")
        w.toolbar = toolbar
        w.toolbarStyle = .unified
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 480, height: 300)
        w.setFrameAutosaveName("KoiMain")
        if !w.setFrameUsingName("KoiMain") { w.center() }
        w.delegate = self
        w.nextResponder = self

        // The glass: the desktop, blurred, behind the whole window.
        let glass = NSVisualEffectView()
        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .active
        w.contentView = glass

        let side = NSHostingView(rootView: SidebarView(machines: machines))
        side.translatesAutoresizingMaskIntoConstraints = false
        // The sidebar reserves topRow for the window-owned header controls.
        side.safeAreaRegions = []
        glass.addSubview(side)
        sidebarView = side

        // The panes' cards (see panes.swift), laid out in this area.
        let card = SplitContainerView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(card)
        self.card = card

        // The header stays fixed beneath the pane as it covers the rail.
        let toggle = NSHostingView(rootView: AnyView(sidebarToggle))
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.safeAreaRegions = []
        glass.addSubview(toggle)
        toggleButton = toggle
        let newTab = NSHostingView(rootView: HStack(spacing: 2) {
            TopRowButton(help: "Command Palette", shortcut: .commandPalette, action: { [weak self] in self?.showCommandPalette(nil) }) {
                Image(systemName: "command").font(.system(size: 14, weight: .medium))
            }
            TopRowButton(help: "New Tab", shortcut: .newTab, action: { [weak self] in self?.workspace.newTab() }) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
            }
        })
        newTab.translatesAutoresizingMaskIntoConstraints = false
        newTab.safeAreaRegions = []
        glass.addSubview(newTab)
        newTabButton = newTab
        glass.addSubview(card, positioned: .above, relativeTo: newTab)
        card.onSurfaceLayout = { [weak self] in self?.updateChromeCoverage() }

        // The horizontal tab bar, shown along the top when `tabs = top` in
        // place of the side sidebar.
        let topBar = NSHostingView(rootView: HorizontalBar(machines: machines))
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.safeAreaRegions = []
        glass.addSubview(topBar)
        topBarView = topBar

        let resize = SidebarResizeHandle()
        resize.translatesAutoresizingMaskIntoConstraints = false
        resize.onBegin = { [weak self] in self?.beginSidebarResize() ?? false }
        resize.onResize = { [weak self] in self?.resizeSidebar(by: $0) }
        resize.onEnd = { [weak self] in self?.endSidebarResize() }
        glass.addSubview(resize)
        resizeHandle = resize

        chromeLayout = ChromeLayout(root: glass, card: card, sidebar: side, toggle: toggle,
                                    actions: newTab, resizeHandle: resize)
        chromeLayout.apply(tabs: Config.current.tabs, sidebarShown: sidebarShown, width: preferredSidebarWidth)
        topBarLeading = topBar.leadingAnchor.constraint(equalTo: glass.leadingAnchor)
        NSLayoutConstraint.activate([
            topBarLeading,
            topBar.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: glass.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.topRow),
        ])
        window = w
        coveredChrome = ([side, toggle, newTab] as [NSView]
            + [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) })
            .map(ChromeCoverage.init)
        installChrome()
        applyWindowAppearance()
        return w
    }

    /// Keep dark glass while honoring transparency preferences and system accessibility.
    func applyWindowAppearance() {
        guard let window else { return }
        window.appearance = NSAppearance(named: .darkAqua)
        let solid = Config.current.solidSurfaces
        let background = NSColor(Theme.current.backgroundColor)
        window.isOpaque = solid
        window.backgroundColor = solid ? background : .clear
        if let glass = window.contentView as? NSVisualEffectView {
            glass.material = solid ? .windowBackground : .sidebar
            glass.blendingMode = solid ? .withinWindow : .behindWindow
            glass.state = solid ? .inactive : .active
            glass.wantsLayer = true
            glass.layer?.backgroundColor = solid ? background.cgColor : NSColor.clear.cgColor
        }
        card?.reloadAppearance()
    }

    /// The sidebar toggle stays in place as the pane covers and uncovers it.
    private var sidebarToggle: some View {
        TopRowButton(help: "Toggle Sidebar", shortcut: .toggleSidebar, action: { [weak self] in
            self?.toggleKoiSidebar(nil)
        }) {
            Image(systemName: Config.current.tabs.isRight ? "sidebar.right" : "sidebar.left")
                .font(.system(size: 15, weight: .medium))
        }
    }

    /// Placement changes seat new geometry under a resize hold. Ordinary reloads
    /// leave an active motion in charge of the installed sidebar fraction.
    func installChrome() {
        let tabs = Config.current.tabs
        let placementChanged = installedTabs != nil && installedTabs != tabs
        let hold = placementChanged ? card.beginResizeHold() : nil
        defer { if let hold { card.endResizeHold(hold) } }
        if placementChanged { endSidebarTransition() }
        installedTabs = tabs
        topBarView.isHidden = tabs.isVertical
        toggleButton.rootView = AnyView(sidebarToggle)
        sidebarView.isHidden = !tabs.isVertical
        newTabButton.isHidden = !tabs.isVertical
        toggleButton.isHidden = !tabs.isVertical
        if sidebarTransition != nil { layoutChrome(); return }
        sidebarProgress = sidebarShown ? 1 : 0
        layoutChrome()
        if placementChanged { resizeHandle.cancel() }
    }

    /// Cut chrome out only where visible pane cards cover it. The actual view
    /// frames drive both drawing and input; native buttons cannot act while covered.
    private func updateChromeCoverage() {
        guard window != nil else { return }
        let surfaces = card.surfaceRects
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for item in coveredChrome {
            let view = item.view
            let rectangles = Config.current.tabs.isVertical ? surfaces.compactMap { surface -> CGRect? in
                let frame = view.convert(surface, from: card)
                return frame.intersects(view.bounds) ? frame : nil
            } : []
            guard !rectangles.isEmpty else { item.restore(); continue }
            var path = CGPath(rect: view.bounds, transform: nil)
            for frame in rectangles {
                let surface = CGPath(roundedRect: frame, cornerWidth: AppDelegate.paneCornerRadius,
                                     cornerHeight: AppDelegate.paneCornerRadius, transform: nil)
                path = path.subtracting(surface)
            }
            item.mask.frame = view.bounds
            item.mask.path = path
            view.layer?.mask = item.mask
            if let button = view as? NSButton, button.isEnabled { button.isEnabled = false }
        }
    }

    /// Seat geometry with pane easing suppressed. Interactive grips retain
    /// their holds; animated chrome uses final live grids and a temporary shell.
    private func layoutChrome() {
        guard !chromeLayout.isLayingOut else { return }
        chromeLayout.isLayingOut = true
        defer { chromeLayout.isLayingOut = false }
        let hold = sidebarResize == nil && sidebarTransition == nil ? card.beginResizeHold() : nil
        if hold != nil { card.setLayoutTransitionActive(true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            let trailing = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> CGFloat? in
                guard let button = window.standardWindowButton(type), let root = window.contentView else { return nil }
                return root.convert(button.bounds, from: button).maxX
            }.max() ?? 74
            topBarLeading.constant = trailing + 8
            chromeLayout.apply(tabs: Config.current.tabs, sidebarShown: sidebarShown, width: preferredSidebarWidth, progress: sidebarProgress)
            window.contentView?.layoutSubtreeIfNeeded()
            updateChromeCoverage()
        }
        resizeHandle.isHidden = !Config.current.tabs.isVertical || !sidebarShown || sidebarTransition != nil
        if let hold {
            card.setLayoutTransitionActive(false)
            card.layoutSubtreeIfNeeded()
            card.endResizeHold(hold)
        }
    }

    /// One mouse sequence owns terminal resize suppression, independent of pane motion.
    private func beginSidebarResize() -> Bool {
        guard sidebarResize == nil, sidebarTransition == nil,
              Config.current.tabs.isVertical, sidebarShown else { return false }
        sidebarResize = (chromeLayout.sidebarWidth.constant, Config.current.tabs, card.beginResizeHold())
        card.setLayoutTransitionActive(true)
        return true
    }

    /// Update the production constraints directly; the grip never animates or tracks events in a loop.
    private func resizeSidebar(by translation: CGFloat) {
        guard let resize = sidebarResize else { return }
        guard Config.current.tabs == resize.tabs, sidebarShown else { resizeHandle.cancel(); return }
        guard translation != 0 || chromeLayout.sidebarWidth.constant != resize.width else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            chromeLayout.resizeSidebar(from: resize.width, translation: translation, tabs: resize.tabs)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        preferredSidebarWidth = chromeLayout.sidebarWidth.constant
    }

    /// Finish or interrupt a drag at its settled width and release only its hold.
    private func endSidebarResize() {
        guard let resize = sidebarResize else { return }
        sidebarResize = nil
        card.setLayoutTransitionActive(false)
        card.layoutSubtreeIfNeeded()
        card.endResizeHold(resize.hold)
        if chromeLayout.sidebarWidth.constant != resize.width {
            UserDefaults.standard.set(Double(preferredSidebarWidth), forKey: "sidebarWidth")
        }
    }

    /// Shows the selected tab's panes, the focused one with the keyboard.
    func show(_ tab: Wire.TabInfo?) {
        let ws = workspace
        if actionsOwner != ObjectIdentifier(ws) {
            actionsOwner = ObjectIdentifier(ws)
            card.actions = SplitContainerView.Actions(
                split: { ws.splitPane($0) },
                zoom: { ws.toggleZoom() },
                close: { ws.closePane() },
                focus: { ws.focus($0) },
                resize: { ws.resizeSplit($0, index: $1, ratio: $2) },
                swap: { ws.swapPanes($0, onto: $1) },
                dragChanged: { [weak self] id, t in self?.card.paneDragChanged(id, t) },
                dragEnded: { [weak self] id, t in self?.card.paneDragEnded(id, t) }
            )
        }
        card.show(tab, focused: ws.focusedPane, zoomed: ws.zoomedPane) { id in
            let v = ws.view(for: id)
            if v.fontSize != fontSize { v.fontSize = fontSize }
            return v
        }
        prunePaneCards()
        // Pane updates arrive while a name field is open; its focus stays put.
        let editing = ws.renamingTab != nil || ws.renamingGroup != nil
        if let view = ws.selectedView {
            if window.firstResponder !== view && !window.hasKoiPopup && !editing { window.makeFirstResponder(view) }
            view.setFocused(window.isKeyWindow)
        }
        let group = ws.tab(ws.selectedTab)?.group?.name ?? ""
        let name = Paths.isDev ? "Koid" : "Koi"
        window.title = group.isEmpty ? name : "\(group) — \(name)"
    }

    /// Cached cards follow terminal ownership across all machines, and are
    /// discarded as soon as their workspace no longer owns the terminal.
    func prunePaneCards() {
        card.prunePaneCards(keeping: machines.allWorkspaces.flatMap(\.attachedViews))
    }

    /// Move the pane over a stationary vertical rail. Reversal starts at the
    /// currently installed fraction; one background shell fills the moving
    /// envelopes while live terminals retain their final grids.
    func toggleSidebar() {
        guard Config.current.tabs.isVertical else { return }
        resizeHandle.cancel()
        resizeHandle.isHidden = true
        TooltipAnchor.Coordinator.current?.dismiss()
        // Nested anchored menus share ownership through `current`. Close their
        // chain in this window before moving anchors; centered palettes stay put.
        while let popup = PopupAnchor.Coordinator.current, popup.isPresented,
              !popup.centered, popup.anchor?.window === window {
            popup.dismiss()
        }
        sidebarShown.toggle()
        if sidebarTransition == nil {
            sidebarTransition = UUID()
        }
        card.setLayoutTransitionActive(true, finalSize: chromeLayout.destinationSize(tabs: Config.current.tabs, sidebarShown: sidebarShown))
        card.layoutSubtreeIfNeeded()
        sidebarMotion = (sidebarProgress, sidebarShown ? 1 : 0, CACurrentMediaTime(),
                         0.22 * Double(max(0.001, abs(sidebarProgress - (sidebarShown ? 1 : 0)))))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || Config.current.motion == .off {
            tickSidebar(at: .greatestFiniteMagnitude)
        } else if sidebarDisplayLink == nil, window.isVisible {
            let link = window.contentView!.displayLink(target: SidebarClock(self), selector: #selector(SidebarClock.tick))
            link.add(to: .main, forMode: .common)
            sidebarDisplayLink = link
        }
        if !sidebarShown { showSidebarHint() }
    }

    /// Advance the same display clock in production and offscreen checks.
    /// Only constraint geometry and coverage change; chrome opacity stays intact.
    func tickSidebar(at time: CFTimeInterval) {
        guard let motion = sidebarMotion, sidebarTransition != nil else { return }
        let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || Config.current.motion == .off
            ? 1 : min(1, max(0, (time - motion.start) / motion.duration))
        let eased = CGFloat(progress * progress * (3 - 2 * progress))
        sidebarProgress = motion.from + (motion.to - motion.from) * eased
        layoutChrome()
        if progress >= 1 {
            endSidebarTransition()
            layoutChrome()
        }
    }

    /// Release this motion's shell and restore clipping on finish, placement
    /// change or teardown. Legacy external tokens, if present, retain ownership.
    private func endSidebarTransition() {
        sidebarDisplayLink?.invalidate()
        sidebarDisplayLink = nil
        sidebarMotion = nil
        sidebarTransition = nil
        card.setLayoutTransitionActive(false)
        card.layoutSubtreeIfNeeded()
        if let hold = sidebarTransitionHold { sidebarTransitionHold = nil; card.endResizeHold(hold) }
    }

    /// Give the selected terminal focus when the main window becomes key.
    func windowDidBecomeKey(_ notification: Notification) { workspace.selectedView?.setFocused(true) }
    /// Losing key focus ends live gestures and clears terminal focus together.
    func windowDidResignKey(_ notification: Notification) {
        resizeHandle?.cancel()
        card.cancelPaneDrag(untilRelease: true)
        workspace.selectedView?.setFocused(false)
    }

}
