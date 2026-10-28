import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Koi

/// Placement checks use the same constraints as the app in a private, unshown
/// window. They check available space and control access rather than styling.
@MainActor struct ChromeTests {
    /// Moving a live rail replaces its anchors without shrinking usable width.
    @Test func switchingEdgesMovesTheRailAndPreservesContentWidth() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.apply(.side)
        let leftPane = fixture.card.frame
        #expect(fixture.sidebar.frame.minX == fixture.root.bounds.minX)
        #expect(leftPane.minX == fixture.sidebar.frame.maxX)
        #expect(!leftPane.intersects(fixture.sidebar.frame))

        fixture.apply(.right)
        #expect(fixture.sidebar.frame.maxX == fixture.root.bounds.maxX)
        #expect(fixture.card.frame.maxX == fixture.sidebar.frame.minX)
        #expect(fixture.card.frame.width == leftPane.width)
        #expect(fixture.card.frame.minX < leftPane.minX)
        #expect(!fixture.card.frame.intersects(fixture.sidebar.frame))
        #expect(fixture.topInset(of: fixture.card) >= AppDelegate.topRow)
        #expect(fixture.sidebar.frame.contains(fixture.toggle.frame))
        #expect(fixture.sidebar.frame.contains(fixture.actions.frame))
        #expect(!fixture.toggle.frame.intersects(fixture.actions.frame))

        // A return to the original edge must deactivate the right anchors.
        fixture.apply(.side)
        #expect(fixture.card.frame == leftPane)
        #expect(fixture.sidebar.frame.minX == fixture.root.bounds.minX)
        #expect(!fixture.sidebar.hasAmbiguousLayout)
        #expect(!fixture.toggle.hasAmbiguousLayout)
    }

    /// Collapsing either edge restores a terminal sheet with no reserved header.
    @Test func collapsedRailsReclaimTheWholeHeader() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        for placement in [Config.Tabs.side, .right] {
            fixture.apply(placement)
            let expandedRailPaneWidth = fixture.card.frame.width
            fixture.apply(placement, shown: false)
            #expect(fixture.card.frame.width > expandedRailPaneWidth)
            #expect(fixture.topInset(of: fixture.card) == AppDelegate.inset)
            #expect(fixture.card.frame.minX == AppDelegate.inset)
            #expect(fixture.card.frame.maxX == fixture.root.bounds.maxX - AppDelegate.inset)
            #expect(!fixture.toggle.hasAmbiguousLayout)
        }
    }

    /// Top placement ignores vertical visibility, including after a window resize.
    @Test func topPlacementUsesFullWidthRegardlessOfVerticalCollapseState() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.apply(.right, shown: false)
        let fullWidth = fixture.card.frame.width
        fixture.apply(.top)
        let pane = fixture.card.frame
        #expect(pane.width == fullWidth)
        #expect(fixture.topInset(of: fixture.card) >= AppDelegate.topRow)
        fixture.apply(.top, shown: false)
        #expect(fixture.card.frame == pane)

        // Resize after changing placement to catch an accidental fixed position.
        fixture.window.setContentSize(NSSize(width: 800, height: 500))
        fixture.apply(.right)
        #expect(fixture.sidebar.frame.maxX == fixture.root.bounds.maxX)
        #expect(fixture.card.frame.maxX == fixture.sidebar.frame.minX)
        #expect(!fixture.card.hasAmbiguousLayout)
    }

    /// Either inner edge changes the real rail width and gives the remainder to panes.
    @Test func resizingEitherRailMovesItsInnerEdgeAndResizesThePane() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        for placement in [Config.Tabs.side, .right] {
            fixture.apply(placement, width: AppDelegate.sidebarWidth)
            let original = fixture.sidebar.frame.width
            let paneWidth = fixture.card.frame.width
            let increase = (ChromeLayout.maximumSidebarWidth - original) / 2
            fixture.resize(from: original, translation: placement.isRight ? -increase : increase,
                           placement: placement)
            #expect(fixture.sidebar.frame.width == original + increase)
            #expect(fixture.card.frame.width == paneWidth - increase)
            #expect(fixture.card.frame.width >= ChromeLayout.minimumContentWidth)
            let edge = placement.isRight ? fixture.sidebar.frame.minX : fixture.sidebar.frame.maxX
            #expect(fixture.handle.frame.midX == edge)
            #expect(fixture.topInset(of: fixture.handle) >= AppDelegate.topRow)
            #expect(!fixture.handle.isHidden)
            #expect(!fixture.handle.hasAmbiguousLayout)

            fixture.apply(placement, shown: false)
            #expect(fixture.handle.isHidden)
        }
        fixture.apply(.top)
        #expect(fixture.handle.isHidden)
    }

    /// Window space takes priority over a wide rail, and both ends of the range clamp.
    @Test func sidebarWidthClampsWithoutTakingTheTerminalMinimum() {
        let fixture = Fixture()
        defer { fixture.window.close() }
        for placement in [Config.Tabs.side, .right] {
            fixture.apply(placement, width: fixture.root.bounds.width)
            #expect(fixture.sidebar.frame.width == ChromeLayout.maximumSidebarWidth)
            fixture.apply(placement, width: 0)
            #expect(fixture.sidebar.frame.width == ChromeLayout.minimumSidebarWidth)
        }
        fixture.window.setContentSize(NSSize(width: ChromeLayout.minimumSidebarWidth
            + ChromeLayout.minimumContentWidth + AppDelegate.inset, height: fixture.root.bounds.height))
        for placement in [Config.Tabs.side, .right] {
            fixture.apply(placement, width: ChromeLayout.maximumSidebarWidth)
            #expect(fixture.sidebar.frame.width < ChromeLayout.maximumSidebarWidth)
            #expect(fixture.sidebar.frame.width > 0)
            #expect(fixture.card.frame.width >= ChromeLayout.minimumContentWidth)
            #expect(fixture.root.bounds.contains(fixture.toggle.frame))
            #expect(!fixture.toggle.frame.intersects(fixture.actions.frame))
        }
    }

    /// A moving grip must keep the mouse-down window origin and release once if removed.
    @Test func resizeHandleUsesWindowTranslationAndFinishesWhenRemoved() throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.apply(.right)
        let initialWidth = fixture.sidebar.frame.width
        let initialX = fixture.handle.frame.midX
        let step = (ChromeLayout.maximumSidebarWidth - initialWidth) / 4
        var translations: [CGFloat] = []
        var finishes = 0
        fixture.handle.onBegin = { true }
        fixture.handle.onResize = { [unowned fixture] translation in
            translations.append(translation)
            fixture.resize(from: initialWidth, translation: translation, placement: .right)
        }
        fixture.handle.onEnd = { finishes += 1 }
        fixture.handle.mouseDown(with: try fixture.mouse(.leftMouseDown, x: initialX))
        fixture.handle.mouseDragged(with: try fixture.mouse(.leftMouseDragged, x: initialX - step))
        fixture.handle.mouseDragged(with: try fixture.mouse(.leftMouseDragged, x: initialX - step * 2))
        #expect(translations == [-step, -step * 2])
        #expect(fixture.sidebar.frame.width == initialWidth + step * 2)
        fixture.handle.removeFromSuperview()
        fixture.handle.cancel()
        #expect(finishes == 1)
    }

    /// A plain AppKit fixture supplies control sizes without loading
    /// workspaces, renderers, a server, or the real app delegate.
    @MainActor private final class Fixture {
        let window: NSWindow
        let root = NSVisualEffectView()
        let card = NSView()
        let sidebar = NSView()
        let toggle = NSView()
        let actions = NSView()
        let handle = SidebarResizeHandle()
        private lazy var layout = ChromeLayout(root: root, card: card, sidebar: sidebar,
                                               toggle: toggle, actions: actions, resizeHandle: handle)

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            for view in [card, sidebar, toggle, actions, handle] {
                view.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(view)
            }
            NSLayoutConstraint.activate([
                toggle.widthAnchor.constraint(equalToConstant: 32),
                toggle.heightAnchor.constraint(equalToConstant: 32),
                actions.widthAnchor.constraint(equalToConstant: 66),
                actions.heightAnchor.constraint(equalTo: toggle.heightAnchor),
            ])
        }

        /// Settle the production constraints synchronously for this placement.
        func apply(_ placement: Config.Tabs, shown: Bool = true, width: CGFloat? = nil) {
            layout.apply(tabs: placement, sidebarShown: shown, width: width)
            root.layoutSubtreeIfNeeded()
        }

        /// Exercise the same signed resize update used by the app's native grip.
        func resize(from width: CGFloat, translation: CGFloat, placement: Config.Tabs) {
            layout.resizeSidebar(from: width, translation: translation, tabs: placement)
            root.layoutSubtreeIfNeeded()
        }

        /// Private fixture events call the grip directly without driving the screen.
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: root.bounds.midY),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        /// Compare top clearance in either AppKit coordinate orientation.
        func topInset(of view: NSView) -> CGFloat {
            root.isFlipped ? view.frame.minY : root.bounds.maxY - view.frame.maxY
        }
    }
}

extension SessionTests {
    /// Pane surfaces cover stationary chrome at full opacity; gaps stay exposed
    /// and native controls cannot act until uncovering restores their prior state.
    @Test @MainActor func sidebarCollapseOccludesStationaryChromeAndReclaimsTheHeader() throws {
        let server = try TestServer()
        defer { server.stop() }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        for placement in [Config.Tabs.side, .right] {
            Config.current.tabs = placement
            let (delegate, window) = makeChromeWindow()
            defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
            let root = try #require(window.contentView)
            let pane = try #require(root.subviews.compactMap { $0 as? SplitContainerView }.first)
            let terminals = showChromeSplit(in: pane)
            let buttons = try chromeButtons(window)
            let hosts = root.subviews.filter {
                $0 !== pane && !($0 is SidebarResizeHandle) && !$0.isHidden
            }
            let sidebar = try #require(hosts.first { $0.frame.height == root.bounds.height })
            let chrome = hosts + buttons
            let frames = chrome.map(\.frame)
            let masks = buttons.map { $0.layer?.mask }
            let enabled = buttons.map(\.isEnabled)
            let expanded = pane.frame
            let paneIndex = try #require(root.subviews.firstIndex(of: pane))
            #expect(hosts.count == 3)
            #expect(hosts.allSatisfy { root.subviews.firstIndex(of: $0)! < paneIndex })
            #expect(!window.isVisible)
            delegate.toggleKoiSidebar(nil)
            let destinationGrids = terminals.map(\.currentGridSize)
            delegate.tickSidebar(at: CACurrentMediaTime() + 0.1)
            #expect(terminals.map(\.currentGridSize) == destinationGrids)
            #expect(chrome.allSatisfy { !$0.isHidden && $0.alphaValue == 1 })
            #expect(chrome.map(\.frame) == frames)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && Config.current.motion != .off {
                #expect(delegate.sidebarProgress > 0 && delegate.sidebarProgress < 1)
                #expect(pane.frame.width > expanded.width)
                #expect(pane.frame.width < root.bounds.width - AppDelegate.inset * 2)
                #expect(terminals.allSatisfy { !$0.holdsResizes })
                let surfaces = pane.surfaceRects.sorted { $0.minY < $1.minY }
                #expect(surfaces.count == 2)
                let first = try #require(surfaces.first)
                let last = try #require(surfaces.last)
                let overlap = pane.frame.intersection(sidebar.frame)
                let covered = NSPoint(x: overlap.midX, y: root.convert(first, from: pane).midY)
                let exposed = NSPoint(x: placement.isRight ? sidebar.frame.maxX - 10 : sidebar.frame.minX + 10,
                                      y: covered.y)
                let gap = root.convert(NSPoint(x: pane.convert(covered, from: root).x,
                                              y: (first.maxY + last.minY) / 2), from: pane)
                let path = try #require((sidebar.layer?.mask as? CAShapeLayer)?.path)
                #expect(!path.contains(sidebar.convert(covered, from: root), using: .evenOdd))
                #expect(path.contains(sidebar.convert(exposed, from: root), using: .evenOdd))
                #expect(path.contains(sidebar.convert(gap, from: root), using: .evenOdd))
                let corner = NSPoint(x: placement.isRight ? first.maxX - 1 : first.minX + 1,
                                     y: first.minY + 1)
                #expect(path.contains(sidebar.convert(corner, from: pane), using: .evenOdd))
                for (index, button) in buttons.enumerated() {
                    let intersected = surfaces.contains { button.convert($0, from: pane).intersects(button.bounds) }
                    if intersected {
                        #expect(!button.isEnabled)
                        let mask = try #require((button.layer?.mask as? CAShapeLayer)?.path)
                        // Sample both sides of pixel-aligned edges. A point
                        // exactly on the boundary has no binary paint coverage.
                        let offset = 0.25 / window.backingScaleFactor
                        for y in [button.bounds.minY + 1, button.bounds.midY, button.bounds.maxY - 1] {
                            for delta in [-offset, offset] {
                                let point = NSPoint(x: button.bounds.midX, y: y + delta)
                                let coveredByPane = surfaces.contains { surface in
                                    CGPath(roundedRect: surface, cornerWidth: AppDelegate.paneCornerRadius,
                                           cornerHeight: AppDelegate.paneCornerRadius, transform: nil)
                                        .contains(pane.convert(point, from: button))
                                }
                                #expect(mask.contains(point, using: .evenOdd) == !coveredByPane,
                                    "placement=\(placement), button=\(index), point=\(point), panePoint=\(pane.convert(point, from: button)), surfaces=\(surfaces)")
                            }
                        }
                    } else {
                        #expect(button.layer?.mask === masks[index])
                        #expect(button.isEnabled == enabled[index])
                    }
                }
                let coveredHit = try #require(root.hitTest(root.convert(covered, to: root.superview)))
                #expect(coveredHit.isDescendant(of: pane))
                let exposedHit = try #require(root.hitTest(root.convert(exposed, to: root.superview)))
                #expect(exposedHit.isDescendant(of: sidebar))
            }
            finishSidebar(delegate)
            #expect(delegate.sidebarProgress == 0)
            #expect(terminals.map(\.currentGridSize) == destinationGrids)
            #expect(chrome.allSatisfy { !$0.isHidden && $0.alphaValue == 1 })
            #expect(chrome.map(\.frame) == frames)
            #expect(buttons.allSatisfy { !$0.isEnabled && $0.layer?.mask != nil })
            for button in buttons {
                let path = try #require((button.layer?.mask as? CAShapeLayer)?.path)
                #expect(!path.contains(NSPoint(x: button.bounds.midX, y: button.bounds.midY), using: .evenOdd))
            }
            #expect(pane.frame.minX == AppDelegate.inset)
            #expect(pane.frame.maxX == root.bounds.maxX - AppDelegate.inset)
            #expect(root.bounds.maxY - pane.frame.maxY == AppDelegate.inset)
            #expect(terminals.allSatisfy { !$0.holdsResizes })
            delegate.toggleKoiSidebar(nil)
            let openingGrids = terminals.map(\.currentGridSize)
            delegate.tickSidebar(at: CACurrentMediaTime() + 0.1)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && Config.current.motion != .off {
                let envelope = try #require(pane.surfaceRects.first)
                let live = try #require(pane.liveSurfaceRects.first)
                let far = root.convert(envelope, from: pane)
                #expect(placement.isRight ? far.minX == pane.frame.minX : far.maxX == pane.frame.maxX)
                #expect(envelope.width > live.width)
                let filler = NSPoint(x: placement.isRight ? (envelope.minX + live.minX) / 2
                                                        : (live.maxX + envelope.maxX) / 2, y: envelope.midY)
                let hit = try #require(root.hitTest(root.convert(pane.convert(filler, to: root), to: root.superview)))
                #expect(hit.isDescendant(of: pane) && !(hit is TerminalView) && !(hit is PaneCard))
                #expect(terminals.map(\.currentGridSize) == openingGrids)
            }
            finishSidebar(delegate)
            #expect(terminals.map(\.currentGridSize) == openingGrids)
            #expect(delegate.sidebarProgress == 1)
            #expect(pane.frame == expanded)
            #expect(chrome.map(\.frame) == frames)
            #expect(chrome.allSatisfy { !$0.isHidden && $0.alphaValue == 1 })
            for (index, button) in buttons.enumerated() {
                #expect(button.layer?.mask === masks[index])
                #expect(button.isEnabled == enabled[index])
            }
            #expect(!window.isVisible)
        }
    }

    /// Window resizing retargets the final grid at the installed fraction.
    /// Reversal retains the shell perimeter while its new destination stays live.
    @Test @MainActor func sidebarResizeAndReversalPreserveInstalledGeometry() throws {
        let server = try TestServer()
        defer { server.stop() }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        for placement in [Config.Tabs.side, .right] {
            Config.current.tabs = placement
            let (delegate, window) = makeChromeWindow()
            defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
            let root = try #require(window.contentView)
            let pane = try #require(root.subviews.compactMap { $0 as? SplitContainerView }.first)
            let terminals = showChromeSplit(in: pane)
            let sidebar = try #require(root.subviews.first { $0 !== pane && $0.frame.height == root.bounds.height })
            delegate.toggleKoiSidebar(nil)
            delegate.tickSidebar(at: CACurrentMediaTime() + 0.1)
            let fraction = delegate.sidebarProgress
            let previousGrids = terminals.map(\.currentGridSize)
            window.setContentSize(NSSize(width: 480, height: 600))
            delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            #expect(delegate.sidebarProgress == fraction)
            let resizedGrids = terminals.map(\.currentGridSize)
            #expect(zip(resizedGrids, previousGrids).allSatisfy { $0.cols < $1.cols })
            #expect(terminals.allSatisfy { !$0.holdsResizes })
            let rail = (sidebar.frame.width - AppDelegate.inset) * fraction
            let pixel = 1 / window.backingScaleFactor
            #expect(abs(pane.frame.minX - AppDelegate.inset - (placement.isRight ? 0 : rail)) <= pixel)
            #expect(abs(root.bounds.maxX - pane.frame.maxX - AppDelegate.inset - (placement.isRight ? rail : 0)) <= pixel)
            let top = AppDelegate.inset + (placement.isRight ? (AppDelegate.topRow - AppDelegate.inset) * fraction : 0)
            #expect(abs(root.bounds.maxY - pane.frame.maxY - top) <= pixel)
            let installed = pane.frame
            let perimeter = pane.surfaceRects
            let owner = delegate.sidebarTransition
            delegate.toggleKoiSidebar(nil)
            let destinationGrids = terminals.map(\.currentGridSize)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && Config.current.motion != .off {
                #expect(delegate.sidebarProgress == fraction)
                #expect(pane.frame == installed)
                #expect(delegate.sidebarTransition == owner)
                #expect(pane.surfaceRects == perimeter)
                #expect(terminals.allSatisfy { !$0.holdsResizes })
            }
            finishSidebar(delegate)
            #expect(delegate.sidebarProgress == 1)
            #expect(terminals.map(\.currentGridSize) == destinationGrids)
            #expect(terminals.allSatisfy { !$0.holdsResizes })
            #expect(try chromeButtons(window).allSatisfy { !$0.isHidden && $0.alphaValue == 1 })
            #expect(!window.isVisible)
        }
    }

    /// Switching a moving rail to Top removes the shell/native masks and
    /// restores button state before any obsolete tick can run.
    @Test @MainActor func changingPlacementDuringMotionRestoresTopWindowControls() throws {
        let server = try TestServer()
        defer { server.stop() }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        Config.current.tabs = .right
        let (delegate, window) = makeChromeWindow()
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
        let root = try #require(window.contentView)
        let pane = try #require(root.subviews.compactMap { $0 as? SplitContainerView }.first)
        let terminals = showChromeSplit(in: pane)
        let hosts = root.subviews.filter { $0 !== pane && !($0 is SidebarResizeHandle) && !$0.isHidden }
        let buttons = try chromeButtons(window)
        let masks = buttons.map { $0.layer?.mask }
        let enabled = buttons.map(\.isEnabled)
        delegate.toggleKoiSidebar(nil)
        delegate.tickSidebar(at: CACurrentMediaTime() + 0.1)
        Config.current.tabs = .top
        delegate.installChrome()
        #expect(delegate.sidebarTransition == nil)
        #expect(terminals.allSatisfy { !$0.holdsResizes })
        #expect(hosts.allSatisfy { $0.isHidden })
        for (index, button) in buttons.enumerated() {
            #expect(!button.isHidden && button.alphaValue == 1)
            #expect(button.layer?.mask === masks[index])
            #expect(button.isEnabled == enabled[index])
        }
        let installed = pane.frame
        finishSidebar(delegate)
        #expect(pane.frame == installed)
        #expect(root.bounds.maxY - pane.frame.maxY == AppDelegate.topRow)
        #expect(!window.isVisible)
    }

    /// Changing placement before the first display tick releases synchronous
    /// suppression; a stale clock cannot hide dividers or reacquire resize holds.
    @Test @MainActor func changingPlacementBeforeFirstSidebarTickKeepsDividersAvailable() throws {
        let server = try TestServer()
        defer { server.stop() }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        Config.current.tabs = .side
        let (delegate, window) = makeChromeWindow()
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
        let root = try #require(window.contentView)
        let pane = try #require(root.subviews.compactMap { $0 as? SplitContainerView }.first)
        let terminals = showChromeSplit(in: pane)
        let divider = try #require(pane.subviews.first { !($0 is PaneCard) })
        #expect(!divider.isHidden)
        delegate.toggleKoiSidebar(nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && Config.current.motion != .off {
            #expect(divider.isHidden)
            #expect(terminals.allSatisfy { !$0.holdsResizes })
        }
        Config.current.tabs = .top
        delegate.installChrome()
        finishSidebar(delegate)
        #expect(!divider.isHidden)
        #expect(terminals.allSatisfy { !$0.holdsResizes })
        #expect(try chromeButtons(window).allSatisfy { !$0.isHidden && $0.alphaValue == 1 })
    }

    /// Closing before or after a tick removes the shell and restores native
    /// controls; stale ticks cannot release an independent resize owner's hold.
    @Test(arguments: [false, true]) @MainActor
    func closingSidebarTransitionRemovesShellAndPreservesExternalResizeHolds(afterFirstTick: Bool) throws {
        let server = try TestServer()
        defer { server.stop() }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        Config.current.tabs = .right
        let (delegate, window) = makeChromeWindow()
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
        let root = try #require(window.contentView)
        let pane = try #require(root.subviews.compactMap { $0 as? SplitContainerView }.first)
        let terminals = showChromeSplit(in: pane)
        let buttons = try chromeButtons(window)
        let masks = buttons.map { $0.layer?.mask }
        let enabled = buttons.map(\.isEnabled)
        let divider = try #require(pane.subviews.first { !($0 is PaneCard) })
        let independentHold = pane.beginResizeHold()
        delegate.toggleKoiSidebar(nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && Config.current.motion != .off { #expect(divider.isHidden) }
        if afterFirstTick { delegate.tickSidebar(at: CACurrentMediaTime() + 0.1) }
        weak var shell = pane.subviews.first { !($0 is PaneCard) && $0 !== divider }
        window.close()
        #expect(shell?.superview == nil)
        #expect(delegate.sidebarTransition == nil)
        #expect(!divider.isHidden)
        #expect(terminals.allSatisfy { $0.holdsResizes })
        for (index, button) in buttons.enumerated() {
            #expect(button.layer?.mask === masks[index])
            #expect(button.isEnabled == enabled[index])
        }
        finishSidebar(delegate)
        #expect(terminals.allSatisfy { $0.holdsResizes })
        pane.endResizeHold(independentHold)
        #expect(terminals.allSatisfy { !$0.holdsResizes })
        #expect(!divider.isHidden)
        #expect(!window.isVisible)
    }

    /// Anchored menus lose their moving source; centered palettes keep their
    /// search responder and restore terminal focus only when actually dismissed.
    @Test @MainActor func sidebarMotionDismissesAnchoredMenusButPreservesCenteredPaletteFocus() throws {
        let server = try TestServer()
        defer { server.stop() }
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.tabs = .side
        let (delegate, window) = makeChromeWindow()
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
        let pane = try #require(delegate.card)
        let terminals = showChromeSplit(in: pane)
        let source = try #require(pane.subviews.first { $0 is PaneCard })
        window.makeFirstResponder(terminals[0])
        let popup = PopupAnchor.Coordinator()
        defer { popup.dismiss() }
        popup.anchor = source
        popup.content = AnyView(Text("Pane actions"))
        popup.show()
        #expect(popup.isPresented && window.hasKoiPopup)
        delegate.toggleKoiSidebar(nil)
        #expect(!popup.isPresented && !window.hasKoiPopup)
        #expect(window.firstResponder === terminals[0])
        finishSidebar(delegate)
        popup.anchor = window.contentView
        popup.centered = true
        popup.show()
        let responder = window.firstResponder
        delegate.toggleKoiSidebar(nil)
        #expect(popup.isPresented && window.hasKoiPopup)
        #expect(window.firstResponder === responder)
        finishSidebar(delegate)
        #expect(window.firstResponder === responder)
        popup.dismiss()
        #expect(window.firstResponder === terminals[0])
    }

    /// A live window preference refresh reaches existing pane materials without
    /// replacing terminal views or leaving desktop sampling behind a solid root.
    @Test @MainActor func windowSolidAppearanceAlsoRefreshesExistingPaneMaterials() throws {
        let server = try TestServer()
        defer { server.stop() }
        let saved = Config.current
        defer { Config.current = saved }
        let (delegate, window) = makeChromeWindow()
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
        let pane = try #require(delegate.card)
        let terminals = showChromeSplit(in: pane)
        let cards = pane.subviews.compactMap { $0 as? PaneCard }
        Config.current.reduceTransparency = true
        delegate.applyWindowAppearance()
        #expect(window.isOpaque)
        #expect(cards.allSatisfy { $0.blendingMode == .withinWindow && $0.layer?.backgroundColor?.alpha == 1 })
        #expect(terminals.allSatisfy { terminal in cards.contains { $0.terminal === terminal && terminal.isDescendant(of: $0) } })
    }

    /// Initialize AppKit before constructing the real window; keep it unshown
    /// and retain it through close so teardown follows Swift ownership.
    @MainActor private func makeChromeWindow() -> (AppDelegate, NSWindow) {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let window = delegate.makeWindow()
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1100, height: 700))
        return (delegate, window)
    }

    /// Unconnected, vertically stacked panes expose live grids, rounded surfaces and
    /// a gap crossing the covered rail without starting shells or driving input.
    @MainActor private func showChromeSplit(in pane: SplitContainerView) -> [TerminalView] {
        let terminals = ["a", "b"].map { TerminalView(pane: $0, at: .local) }
        let panes = terminals.map {
            Wire.PaneInfo(id: $0.paneID, pid: 1, title: "", cwd: "/tmp", home: "/tmp",
                          program: "", shell: "zsh", fullscreen: false, status: .idle)
        }
        let layout = Wire.LayoutNode.split(.init(id: "split", direction: .down,
            children: terminals.map { .init(layout: .pane($0.paneID), weight: 1) }))
        pane.show(.init(id: "tab", panes: panes, layout: layout), focused: "a", zoomed: nil) { id in
            terminals.first { $0.paneID == id }!
        }
        pane.layoutSubtreeIfNeeded()
        return terminals
    }

    /// Inspect real native controls in an unshown window, without desktop input.
    @MainActor private func chromeButtons(_ window: NSWindow) throws -> [NSButton] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try #require(window.standardWindowButton($0))
        }
    }

    /// Finish the production clock deterministically without a display or run-loop wait.
    @MainActor private func finishSidebar(_ delegate: AppDelegate) {
        delegate.tickSidebar(at: CACurrentMediaTime() + 1)
        #expect(delegate.sidebarTransition == nil)
    }
}
