import AppKit
import QuartzCore
import Testing
@testable import Koi

@MainActor extension SessionTests {
    /// A resize hold follows its owner across tab switches, covering departed
    /// and newly shown terminals alike; owners cannot release one another's
    /// holds, and a stale completion cannot release the same token twice.
    @Test @MainActor func resizeHoldsFollowTabsAndBelongToTheirOwners() {
        let fixture = PaneFixture()
        fixture.show("a")
        let sidebar = fixture.container.beginResizeHold()
        let split = fixture.container.beginResizeHold()
        #expect(fixture.a.holdsResizes)
        fixture.show("b")
        #expect(fixture.b.holdsResizes)
        fixture.show("a")
        fixture.container.endResizeHold(split)
        fixture.container.endResizeHold(split)
        #expect(fixture.a.holdsResizes && fixture.b.holdsResizes)
        fixture.container.endResizeHold(sidebar)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
    }

    /// A new split slides out from the pane it was split from, fully opaque
    /// throughout: a translucent card would show the glass behind it.
    @Test @MainActor func newPanesSlideFromTheirDividerWithoutFading() throws {
        let fixture = PaneFixture()
        fixture.show(["a"])
        fixture.show(["a", "b"], layoutNow: false)
        fixture.container.layoutSubtreeIfNeeded()
        let b = try #require(fixture.b.paneCard)
        let a = try #require(fixture.a.paneCard)
        #expect(b.alphaValue == 1)
        #expect(b.frame.minX < a.frame.maxX, "the new pane starts toward its sibling, under the gap")
        fixture.container.tickMotion(at: CACurrentMediaTime() + 0.05)
        #expect(b.alphaValue == 1, "no frame of the reveal is translucent")
        fixture.container.tickMotion(at: .greatestFiniteMagnitude)
        #expect(b.alphaValue == 1 && b.frame.minX > a.frame.maxX)
        fixture.finish()
    }

    /// Two shows before layout and further focus/header refreshes must preserve
    /// an appearing card's motion and let the original transition finish.
    @Test @MainActor func repeatedShowPreservesAppearingCards() throws {
        let fixture = PaneFixture()
        fixture.show(["a"])
        fixture.show(["a", "b"], layoutNow: false)
        let b = try #require(fixture.b.paneCard)
        #expect(b.alphaValue == 1)
        fixture.show(["a", "b"], focused: "b", layoutNow: false)
        fixture.container.layoutSubtreeIfNeeded()
        fixture.container.tickMotion(at: CACurrentMediaTime() + 0.1)
        let alpha = b.alphaValue
        let frame = b.frame
        fixture.show(["a", "b"], focused: "a")
        #expect(b.alphaValue == alpha)
        #expect(b.frame == frame)
        fixture.finish()
        #expect(b.alphaValue == 1)
        #expect(!b.isHidden)
        #expect(!fixture.a.holdsResizes)
        #expect(!fixture.b.holdsResizes)
    }

    /// Active and committed divider feedback survives stale/unrelated echoes,
    /// including a tab round trip. Only confirmation releases the override.
    @Test @MainActor func dividerWeightsPersistUntilConfirmed() throws {
        let fixture = PaneFixture()
        fixture.show(["a", "b"])
        let a = try #require(fixture.a.paneCard)
        let divider = try #require(fixture.container.subviews.first { !($0 is PaneCard) })
        fixture.container.resizeDivider(split: "split", index: 0, ratio: 0.7, done: false)
        fixture.container.layoutSubtreeIfNeeded()
        let optimistic = a.frame
        fixture.show(["a", "b"], weights: [7, 3])
        fixture.show(["a", "b"], focused: "b")
        #expect(a.frame == optimistic)
        #expect(divider.superview === fixture.container)
        fixture.container.resizeDivider(split: "split", index: 0, ratio: 0.7, done: true)
        fixture.show(["a", "b"], weights: [6, 4])
        fixture.finish()
        #expect(a.frame == optimistic)
        fixture.show("c")
        fixture.show(["a", "b"])
        #expect(a.frame == optimistic)
        fixture.show(["a", "b"], weights: [7, 3])
        fixture.show(["a", "b"], weights: [3, 7])
        fixture.finish()
        #expect(a.frame.width < optimistic.width)
    }

    /// Closed cards leave before survivors reveal their final live grid. The
    /// presentation clock cannot release another owner's explicit resize hold.
    @Test @MainActor func closingPaneRevealsSurvivorWithoutAnOverlappingGhost() throws {
        let fixture = PaneFixture()
        fixture.show(["a", "b"])
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        let sidebar = fixture.container.beginResizeHold()
        fixture.show(["a"])
        #expect(b.superview == nil && !b.acceptsPaneInput)
        #expect(a.frame == fixture.container.bounds)
        let liveFrame = fixture.a.frame
        fixture.container.tickMotion(at: CACurrentMediaTime() + 0.05)
        #expect(fixture.a.frame == liveFrame)
        let hit = try #require(fixture.container.hitTest(NSPoint(x: 450, y: 200)))
        #expect(hit === a || hit.isDescendant(of: a))
        fixture.show(["a"], focused: "a")
        fixture.finish()
        #expect(a.alphaValue == 1)
        #expect(fixture.a.holdsResizes)
        fixture.container.endResizeHold(sidebar)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
    }

    /// Reversal preserves visible position/opacity while seating the new final
    /// size once. A late tick cannot hide a survivor or release an external hold.
    @Test @MainActor func zoomCanReverseAndRetargetWithoutSnapping() throws {
        let fixture = PaneFixture()
        fixture.show(["a", "b"])
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        let sidebar = fixture.container.beginResizeHold()
        fixture.show(["a", "b"], zoomed: "a")
        fixture.container.tickMotion(at: CACurrentMediaTime() + 0.1)
        let interrupted = a.frame.origin
        let alpha = a.alphaValue
        fixture.show(["a", "b"])
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && Config.current.motion != .off {
            #expect(a.frame.origin == interrupted && a.alphaValue == alpha)
        }
        fixture.show(["a", "b"], zoomed: "b")
        fixture.finish()
        #expect(b.frame == fixture.container.bounds)
        #expect(a.isHidden && !a.acceptsPaneInput)
        fixture.show(["a", "b"])
        fixture.finish()
        #expect(!a.isHidden && !b.isHidden)
        #expect(a.alphaValue == 1 && b.alphaValue == 1)
        fixture.container.tickMotion(at: .greatestFiniteMagnitude)
        #expect(fixture.a.holdsResizes && fixture.b.holdsResizes)
        fixture.container.endResizeHold(sidebar)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
    }

    /// Reorder acknowledgements and animated survivors cannot move the card
    /// away from translation or cause a swap back inside the latched region.
    @Test @MainActor func dragUsesStableSlotsAndSettlesOnCancellation() throws {
        let fixture = PaneFixture()
        fixture.show(["a", "b"])
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        let original = a.frame
        let translation = CGSize(width: b.frame.midX - a.frame.midX, height: 0)
        var swaps: [String] = []
        fixture.onSwap = { _, target in swaps.append(target) }
        fixture.container.paneDragChanged("a", translation)
        #expect(swaps == ["b"])
        fixture.show(["b", "a"])
        fixture.container.tickMotion(at: CACurrentMediaTime() + 0.1)
        fixture.container.paneDragChanged("a", CGSize(width: translation.width + 1, height: 0))
        #expect(swaps == ["b"])
        #expect(a.frame.minX == original.minX + translation.width + 1)
        fixture.container.paneDragChanged("a", .zero)
        #expect(swaps == ["b", "b"])
        fixture.show(["a", "b"])
        fixture.finish()
        fixture.container.paneDragChanged("a", CGSize(width: 60, height: 0))
        let released = a.frame
        fixture.container.cancelPaneDrag()
        fixture.container.layoutSubtreeIfNeeded()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(a.frame == released) }
        fixture.finish()
        #expect(a.frame == original)
        #expect(a.alphaValue == 1 && a.layer?.zPosition == 0)
        fixture.container.paneDragChanged("a", CGSize(width: 20, height: 0))
        fixture.container.cancelPaneDrag(untilRelease: true)
        fixture.finish()
        fixture.container.paneDragChanged("a", CGSize(width: 40, height: 0))
        #expect(!fixture.container.isDraggingPane)
        #expect(a.frame == original)
        fixture.container.paneDragEnded("a", .zero)
        fixture.container.paneDragChanged("a", CGSize(width: 20, height: 0))
        #expect(fixture.container.isDraggingPane)
        fixture.container.cancelPaneDrag()
        fixture.finish()
    }

    /// Zoomed-out cards are neither drag sources nor reorder targets, even
    /// though their cached logical slots still exist in the layout tree.
    @Test @MainActor func hiddenPanesCannotParticipateInDrag() throws {
        let fixture = PaneFixture()
        fixture.show(["a", "b"], zoomed: "a")
        fixture.finish()
        let b = try #require(fixture.b.paneCard)
        var swaps = 0
        fixture.onSwap = { _, _ in swaps += 1 }
        fixture.container.paneDragChanged("b", CGSize(width: 40, height: 0))
        #expect(b.layer?.zPosition == 0)
        fixture.container.paneDragChanged("a", CGSize(width: 150, height: 0))
        #expect(swaps == 0)
        fixture.container.cancelPaneDrag()
        fixture.finish()
    }

    /// A tab round trip reuses its cards and resets lift/opacity. A late end
    /// from the old tab cannot cancel a different pane's new drag.
    @Test @MainActor func switchingTabsCancelsDragAndReusesCards() throws {
        let fixture = PaneFixture()
        fixture.show(["a", "b"])
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        fixture.container.paneDragChanged("a", CGSize(width: 40, height: 0))
        fixture.show("c")
        #expect(a.alphaValue == 1 && a.layer?.zPosition == 0)
        let c = try #require(fixture.c.paneCard)
        fixture.container.paneDragChanged("c", CGSize(width: 30, height: 0))
        fixture.container.paneDragEnded("a", .zero)
        #expect(c.layer?.zPosition != 0)
        fixture.show(["a", "b"])
        #expect(fixture.a.isDescendant(of: a) && fixture.b.isDescendant(of: b))
        #expect(c.alphaValue == 1 && c.layer?.zPosition == 0)
        #expect(a.alphaValue == 1 && a.layer?.zPosition == 0)
        #expect(a.frame.minX == 0)
    }

    /// Cache eviction must release the wrapper after AppKit/SwiftUI autorelease
    /// and Core Animation transactions drain, while the terminal stays alive.
    @Test @MainActor func pruningReleasesDeadCachedCards() async throws {
        let fixture = PaneFixture()
        weak var old: PaneCard?
        autoreleasepool {
            fixture.show("a")
            old = fixture.a.paneCard
            fixture.show("b")
            // Record only a Boolean, so the test reporter cannot retain a card.
            let cached = old != nil
            #expect(cached)
            fixture.container.prunePaneCards(keeping: [fixture.b])
            CATransaction.flush()
        }
        // Hosting-view cleanup can be deferred to a later main-loop turn. A
        // real retain cycle still fails this bounded lifetime assertion.
        for _ in 0..<20 {
            if old == nil { break }
            try await Task.sleep(for: .milliseconds(10))
            autoreleasepool { CATransaction.flush() }
        }
        #expect(old == nil)
    }

    /// Window removal settles the reveal without stealing an external hold;
    /// the same headless clock remains manually drivable.
    @Test @MainActor func windowRemovalSettlesMotionWithoutReleasingExternalHolds() throws {
        let fixture = PaneFixture()
        fixture.show(["a"])
        let sidebar = fixture.container.beginResizeHold()
        fixture.show(["a", "b"])
        fixture.container.viewDidMoveToWindow()
        let b = try #require(fixture.b.paneCard)
        #expect(b.alphaValue == 1)
        fixture.container.setLayoutTransitionActive(true, finalSize: NSSize(width: 900, height: 400))
        fixture.container.layoutSubtreeIfNeeded()
        fixture.container.viewDidMoveToWindow()
        #expect(fixture.container.subviews.filter { !($0 is PaneCard) }.allSatisfy { !$0.isHidden })
        #expect(fixture.a.holdsResizes && fixture.b.holdsResizes)
        fixture.container.endResizeHold(sidebar)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
        fixture.container.tickMotion(at: .greatestFiniteMagnitude)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
    }

    /// Equal server IDs on two workspaces cannot share a wrapper or reparent
    /// one workspace's terminal into the other workspace's cached card.
    @Test @MainActor func cardCacheUsesTerminalIdentityAcrossWorkspaces() throws {
        let fixture = PaneFixture()
        fixture.show("a")
        let original = try #require(fixture.a.paneCard)
        let other = TerminalView(pane: "a", at: .local)
        let pane = Wire.PaneInfo(id: "a", pid: 1, title: "", cwd: "/tmp", home: "/tmp",
                                 program: "", shell: "zsh", fullscreen: false, status: .idle)
        fixture.container.show(.init(id: "a", panes: [pane], layout: .pane("a")), focused: "a", zoomed: nil) { _ in other }
        fixture.container.layoutSubtreeIfNeeded()
        let replacement = try #require(other.paneCard)
        #expect(replacement !== original)
        #expect(original.terminal === fixture.a)
        fixture.show("a")
        #expect(fixture.a.isDescendant(of: original))
        #expect(other.isDescendant(of: replacement))
    }

    /// Container motion follows external sidebar geometry directly and cannot
    /// release the sidebar's independently owned terminal hold.
    @Test @MainActor func externalLayoutTransitionCoordinatesPaneMotion() throws {
        let fixture = PaneFixture()
        fixture.show(["a"])
        let sidebar = fixture.container.beginResizeHold()
        fixture.show(["a", "b"])
        fixture.container.setLayoutTransitionActive(true)
        fixture.container.setFrameSize(NSSize(width: 900, height: 400))
        fixture.container.needsLayout = true
        fixture.container.layoutSubtreeIfNeeded()
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        #expect(a.alphaValue == 1 && b.alphaValue == 1)
        #expect(b.frame.maxX == fixture.container.bounds.maxX)
        #expect(fixture.a.holdsResizes && fixture.b.holdsResizes)
        fixture.container.setLayoutTransitionActive(false)
        fixture.container.endResizeHold(sidebar)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
    }

    /// Split/zoom live sizes settle before visual motion and remain unchanged
    /// on every clock tick, so neither stale grids nor repeated resizes recur.
    @Test @MainActor func paneMotionSeatsTheFinalLiveGridBeforeRevealing() throws {
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.motion = .natural
        let fixture = PaneFixture()
        let window = fixture.host()
        defer { window.close() }
        fixture.show(["a"])
        let original = fixture.a.currentGridSize
        fixture.show(["a", "b"])
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        let grid = fixture.a.currentGridSize
        let frame = fixture.a.frame
        #expect(grid.cols < original.cols)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
        for delta in [0.02, 0.06, 0.1] {
            fixture.container.tickMotion(at: CACurrentMediaTime() + delta)
            #expect(fixture.a.currentGridSize == grid && fixture.a.frame == frame)
            #expect(fixture.b.frame.width == fixture.a.frame.width)
        }
        fixture.finish()
        #expect(a.alphaValue == 1 && b.alphaValue == 1)
        fixture.show(["a", "b"], zoomed: "a")
        #expect(a.frame == fixture.container.bounds)
        #expect(fixture.a.currentGridSize == original)
        #expect(!fixture.a.holdsResizes)
        fixture.finish()
    }

    /// Reduce-motion policy takes effect during an interrupted transition and
    /// restores live dividers immediately, without touching someone else's hold.
    @Test @MainActor func disablingMotionSettlesInFlightRevealAndRestoresDividers() throws {
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.motion = .natural
        let fixture = PaneFixture()
        fixture.show(["a"])
        let hold = fixture.container.beginResizeHold()
        fixture.show(["a", "b"])
        let b = try #require(fixture.b.paneCard)
        Config.current.motion = .off
        NotificationCenter.default.post(name: Config.didReload, object: nil)
        fixture.container.layoutSubtreeIfNeeded()
        #expect(b.alphaValue == 1 && !b.isHidden)
        #expect(fixture.container.subviews.filter { !($0 is PaneCard) }.allSatisfy { !$0.isHidden })
        #expect(fixture.a.holdsResizes && fixture.b.holdsResizes)
        fixture.container.endResizeHold(hold)
        #expect(!fixture.a.holdsResizes && !fixture.b.holdsResizes)
    }

    /// Live preferences change content geometry and focus treatment, retaining
    /// the same terminal objects rather than replacing or merely hiding text.
    @Test @MainActor func panePreferencesChangeLiveLayoutAndFocusTreatment() throws {
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.showPaneHeaders = true
        Config.current.compactPanes = false
        Config.current.fadeInactivePanes = true
        let fixture = PaneFixture()
        let window = fixture.host()
        defer { window.close() }
        fixture.show(["a", "b"])
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        let headerSpace = fixture.a.frame.minY
        let gap = b.frame.minX - a.frame.maxX
        let rows = fixture.a.currentGridSize.rows
        #expect(fixture.b.alphaValue < fixture.a.alphaValue)
        Config.current.compactPanes = true
        NotificationCenter.default.post(name: Config.didReload, object: nil)
        fixture.finish()
        #expect(fixture.a.frame.minY < headerSpace)
        #expect(b.frame.minX - a.frame.maxX < gap)
        Config.current.showPaneHeaders = false
        Config.current.fadeInactivePanes = false
        NotificationCenter.default.post(name: Config.didReload, object: nil)
        fixture.finish()
        #expect(fixture.a.frame.minY == 0)
        #expect(fixture.a.currentGridSize.rows > rows)
        #expect(fixture.a.alphaValue == fixture.b.alphaValue)
        #expect(fixture.a.isDescendant(of: a) && fixture.b.isDescendant(of: b))
    }

    /// Pointer focus works across the entire card without headers and respects
    /// the opt-in, current keyboard window and hidden-pane input policy.
    @Test @MainActor func pointerFocusRespectsPreferenceAndPaneVisibility() throws {
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.focusFollowsMouse = false
        Config.current.showPaneHeaders = false
        let fixture = PaneFixture()
        let window = PanePointerWindow(contentRect: fixture.container.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = fixture.container
        defer { window.close() }
        fixture.show(["a", "b"])
        let b = try #require(fixture.b.paneCard)
        var focused: [String] = []
        fixture.onFocus = { focused.append($0) }
        fixture.show(["a", "b"])
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        b.mouseEntered(with: event)
        #expect(focused.isEmpty)
        Config.current.focusFollowsMouse = true
        b.mouseEntered(with: event)
        #expect(focused == ["b"])
        fixture.container.setLayoutTransitionActive(true, finalSize: fixture.container.bounds.size)
        fixture.container.layoutSubtreeIfNeeded()
        b.mouseEntered(with: event)
        #expect(focused == ["b"], "moving surfaces must not transfer keyboard focus under a stationary pointer")
        fixture.container.setLayoutTransitionActive(false)
        fixture.container.layoutSubtreeIfNeeded()
        b.acceptsPaneInput = false
        b.mouseEntered(with: event)
        #expect(focused == ["b"])
        b.acceptsPaneInput = true
        b.isHidden = true
        b.mouseEntered(with: event)
        #expect(focused == ["b"])
        b.isHidden = false
        window.acceptsPointerFocus = false
        b.mouseEntered(with: event)
        #expect(focused == ["b"])
    }

    /// Focus changes cannot recolor live borders, before, during or after a
    /// sidebar transition.
    @Test @MainActor func focusChangesPreservePaneBorderColors() throws {
        let fixture = PaneFixture()
        let window = fixture.host()
        defer { window.close() }
        fixture.show(["a", "b"], focused: "a")
        let a = try #require(fixture.a.paneCard)
        let b = try #require(fixture.b.paneCard)
        let border = try #require(a.layer?.borderColor)
        #expect(b.layer?.borderColor == border)
        fixture.show(["a", "b"], focused: "b")
        #expect(a.layer?.borderColor == border && b.layer?.borderColor == border)
        fixture.container.setLayoutTransitionActive(true, finalSize: NSSize(width: 400, height: 400))
        fixture.container.layoutSubtreeIfNeeded()
        fixture.show(["a", "b"], focused: "a")
        #expect(a.layer?.borderColor == border && b.layer?.borderColor == border)
        fixture.container.setLayoutTransitionActive(false)
        fixture.container.layoutSubtreeIfNeeded()
        #expect(a.layer?.borderColor == border && b.layer?.borderColor == border)
    }

    /// The one shell fills each moving envelope while live cards stay at final
    /// size. Filler clicks never reach a terminal, and overflow cannot cross gaps.
    @Test @MainActor func sidebarShellMatchesLiveClippingAndBlocksOnlyItsFilledBand() throws {
        let saved = Config.current
        defer { Config.current = saved }
        for placement in [Config.Tabs.side, .right] {
            Config.current.tabs = placement
            let fixture = PaneFixture()
            let window = fixture.host()
            defer { window.close() }
            fixture.show(["a", "b"])
            let a = try #require(fixture.a.paneCard)
            let initialSubviews = fixture.container.subviews.count
            fixture.container.setLayoutTransitionActive(true, finalSize: NSSize(width: 400, height: 400))
            fixture.container.layoutSubtreeIfNeeded()
            #expect(fixture.container.subviews.count == initialSubviews + 1)
            let envelope = try #require(fixture.container.surfaceRects.first)
            let live = try #require(fixture.container.liveSurfaceRects.first)
            #expect(envelope.width > live.width)
            #expect(placement.isRight ? a.frame.maxX == envelope.maxX : a.frame.minX == envelope.minX)
            let x = placement.isRight ? (envelope.minX + live.minX) / 2 : (live.maxX + envelope.maxX) / 2
            let filler = NSPoint(x: x, y: envelope.midY)
            let hit = try #require(fixture.container.hitTest(filler))
            #expect(hit.superview === fixture.container && !(hit is PaneCard))
            #expect(!hit.isDescendant(of: a))
            window.makeFirstResponder(fixture.a)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: fixture.container.convert(filler, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            hit.mouseDown(with: event)
            #expect(window.firstResponder === fixture.a)
            let shell = hit
            let perimeter = fixture.container.surfaceRects
            fixture.container.setLayoutTransitionActive(true, finalSize: NSSize(width: 900, height: 400))
            fixture.container.layoutSubtreeIfNeeded()
            #expect(fixture.container.surfaceRects == perimeter, "reversal cannot jump the visible envelope")
            #expect(shell.superview === fixture.container)
            #expect(a.frame.width > envelope.width)
            let clipped = try #require(fixture.container.liveSurfaceRects.first)
            #expect(clipped == envelope)
            #expect(fixture.a.visibleRect.width <= clipped.width)
            let terminalClip = fixture.a.convert(envelope, from: fixture.container).intersection(fixture.a.bounds)
            #expect(fixture.a.visibleRect == terminalClip, "native mouse coordinates must follow the same clipped document region")
            #expect(fixture.a.frame.width == a.bounds.width, "clipping must preserve the final live grid width")
            let gapPoint = NSPoint(x: envelope.maxX + SplitContainerView.gap / 2, y: envelope.midY)
            #expect(fixture.container.hitTest(gapPoint) !== a)
            fixture.container.setLayoutTransitionActive(false)
            fixture.container.layoutSubtreeIfNeeded()
            #expect(shell.superview == nil)
            #expect(fixture.container.subviews.count == initialSubviews)
            #expect(a.layer?.mask == nil && a.allowsPointerFocus)
        }
    }


}

/// Real terminal/card hierarchies with no connections or screen input. Tests
/// may host them in an invisible fixture window to exercise native routing.
@MainActor private final class PaneFixture {
    let container = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let a = TerminalView(pane: "a", at: .local)
    let b = TerminalView(pane: "b", at: .local)
    let c = TerminalView(pane: "c", at: .local)
    var onSwap: ((String, String) -> Void)?
    var onFocus: ((String) -> Void)?

    /// Supply native backing scale and a real terminal viewport without
    /// ordering a window on screen or attaching any terminal connection.
    func host() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: container.frame)
        window.contentView = root
        root.addSubview(container)
        return window
    }

    /// Show a single-pane tab, used for tab-switch and hold ownership checks.
    func show(_ id: String) { show([id], tabID: id) }

    /// Refresh a server snapshot and optionally defer its first layout, allowing
    /// tests to exercise multiple shows in the same main-loop turn.
    func show(_ ids: [String], tabID: String = "tab", weights: [Double] = [1, 1],
              focused: String? = nil, zoomed: String? = nil, layoutNow: Bool = true) {
        _ = NSApplication.shared
        container.actions = .init(split: { _ in }, zoom: {}, close: {}, focus: { [weak self] in self?.onFocus?($0) },
            resize: { _, _, _ in }, swap: { [weak self] in self?.onSwap?($0, $1) },
            dragChanged: { _, _ in }, dragEnded: { _, _ in })
        let panes = ids.map { Wire.PaneInfo(id: $0, pid: 1, title: "", cwd: "/tmp", home: "/tmp",
            program: "", shell: "zsh", fullscreen: false, status: .idle) }
        let layout: Wire.LayoutNode = ids.count == 1 ? .pane(ids[0]) : .split(.init(id: "split", direction: .right,
            children: ids.enumerated().map { .init(layout: .pane($0.element), weight: weights[$0.offset]) }))
        let tab = Wire.TabInfo(id: tabID, panes: panes, layout: layout)
        container.show(tab, focused: focused ?? ids.first, zoomed: zoomed) { id in
            switch id { case "a": self.a; case "b": self.b; default: self.c }
        }
        if layoutNow { container.layoutSubtreeIfNeeded() }
    }

    /// Complete the production animation clock deterministically, without sleep.
    func finish() {
        container.layoutSubtreeIfNeeded()
        container.tickMotion(at: .greatestFiniteMagnitude)
    }
}

/// Simulates key-window routing without activating a window on the desktop.
@MainActor private final class PanePointerWindow: NSWindow {
    var acceptsPointerFocus = true
    override var isKeyWindow: Bool { acceptsPointerFocus }
}

/// Card identity survives native viewport/document wrappers inside the pane.
@MainActor private extension TerminalView {
    var paneCard: PaneCard? {
        var parent = superview
        while let view = parent {
            if let card = view as? PaneCard { return card }
            parent = view.superview
        }
        return nil
    }
}
