import AppKit
import Testing
@testable import Koi

/// Dragging only chooses a release intent: server order and group membership
/// remain authoritative, and cancellation leaves no delayed work behind.
@Suite @MainActor struct TabDragTests {
    /// Expanding a selection must not change the source under an already pressed pointer.
    @Test func selectionReflowKeepsTheOriginallyPressedTab() {
        let drag = TabDrag(horizontal: true)
        let state = fixture(drag)
        drag.record(.tab("a"), frame: CGRect(x: 0, y: 0, width: 200, height: 34))
        drag.record(.tab("b"), frame: CGRect(x: 206, y: 0, width: 100, height: 34))
        drag.begin(at: CGPoint(x: 150, y: 17), state: state, renaming: nil, pressedTab: "b")
        #expect(drag.source?.id == "b")
        drag.cancel()
    }

    @Test(arguments: [false, true]) func insertionReturnsOneIntentAndClearsImmediately(horizontal: Bool) throws {
        let drag = TabDrag(horizontal: horizontal)
        let state = fixture(drag)
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        drag.update(to: point(195, horizontal))
        #expect(drag.active && drag.source?.id == "a")
        #expect(drag.placement == .insert("b", after: true, outside: false))
        #expect(state.tabs.map(\.id) == ["a", "b", "c"])
        let move = try #require(drag.finish())
        #expect(move.0 == "a")
        #expect(move.1 == .insert("b", after: true, outside: false))
        #expect(!drag.active && drag.source == nil && drag.placement == nil)
        #expect(state.tabs.map(\.id) == ["a", "b", "c"])
        drag.reconcile(state)
        #expect(drag.finish() == nil, "a release cannot emit a second commit")
    }

    @Test(arguments: [false, true]) func groupEdgesDistinguishMembershipFromExtraction(horizontal: Bool) throws {
        let drag = TabDrag(horizontal: horizontal)
        _ = fixture(drag)
        let state = Wire.State(items: [.tab(tab("a")), .group(.init(id: "g", name: "Work", tabs: [tab("b"), tab("c")]))])
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        drag.update(to: point(104, horizontal))
        #expect(drag.placement == .insert("b", after: false, outside: true))
        drag.update(to: point(108, horizontal))
        #expect(drag.placement == .insert("b", after: false, outside: true))
        drag.update(to: point(132, horizontal))
        #expect(drag.placement == .insert("b", after: false, outside: false))
        drag.update(to: point(200, horizontal))
        #expect(drag.placement == .insert("b", after: true, outside: false))
        drag.update(to: point(214, horizontal))
        #expect(drag.placement == .insert("c", after: false, outside: false))
        drag.update(to: point(286, horizontal))
        #expect(drag.placement == .insert("c", after: true, outside: false))
        drag.update(to: point(310, horizontal))
        #expect(try #require(drag.finish()).1 == .insert("c", after: true, outside: true))
        #expect(state.items.map(\.id) == ["a", "g"])
        #expect(state.tabs.map(\.id) == ["a", "b", "c"])
    }

    @Test(arguments: [false, true]) func anExistingHeaderAcceptsDropsWithItsMembersHidden(horizontal: Bool) throws {
        let drag = TabDrag(horizontal: horizontal)
        let state = Wire.State(items: [.tab(tab("a")), .group(.init(id: "g", name: "Work", tabs: [tab("b"), tab("c")]))])
        drag.record(.tab("a"), frame: frame(0, horizontal))
        drag.record(.group("g"), frame: frame(106, horizontal))
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        drag.update(to: point(156, horizontal))
        #expect(drag.placement == .intoGroup("g"), "an actual header hit needs no dwell timer")
        drag.update(to: point(210, horizontal))
        #expect(drag.placement == nil, "a gap outside the header must not join the group")
        drag.update(to: point(156, horizontal))
        #expect(try #require(drag.finish()).1 == .intoGroup("g"))
        #expect(!drag.active && drag.source == nil && drag.placement == nil)
    }

    @Test(arguments: [false, true]) func sourceBodyAndEndAreaHaveExplicitReleaseIntent(horizontal: Bool) throws {
        let drag = TabDrag(horizontal: horizontal)
        let state = fixture(drag)
        drag.record(.end, frame: frame(318, horizontal))
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        drag.update(to: point(195, horizontal))
        drag.update(to: point(10, horizontal))
        #expect(drag.placement == nil)
        #expect(drag.finish() == nil, "releasing over the source does not move it")
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        drag.update(to: point(330, horizontal))
        #expect(try #require(drag.finish()).1 == .end)
    }

    @Test(arguments: [false, true]) func renamingAndTrailingControlsCannotStartDragging(horizontal: Bool) {
        let drag = TabDrag(horizontal: horizontal)
        let state = fixture(drag)
        drag.begin(at: point(10, horizontal), state: state, renaming: "a")
        #expect(!drag.active)
        let controls = horizontal ? CGPoint(x: 95, y: 17) : CGPoint(x: 195, y: 10)
        drag.begin(at: controls, state: state, renaming: nil)
        #expect(!drag.active)
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        drag.update(to: point(195, horizontal))
        drag.cancel()
        drag.update(to: point(250, horizontal))
        #expect(!drag.active && drag.source == nil && drag.placement == nil)
        #expect(drag.finish() == nil)
    }

    @Test func metadataCanChangeButATreeChangeCancelsTheGesture() {
        let drag = TabDrag(horizontal: true)
        let state = fixture(drag)
        var renamed = state
        renamed.items[0] = .tab(.init(id: "a", name: "Renamed", panes: [], layout: .pane("a")))
        let changes = [
            Wire.State(items: [.tab(tab("b")), .tab(tab("c"))]),
            Wire.State(items: [.tab(tab("a")), .tab(tab("c")), .tab(tab("b"))]),
            Wire.State(items: [.tab(tab("a")), .group(.init(id: "g", name: "Work", tabs: [tab("b"), tab("c")]))])
        ]
        for changed in changes {
            drag.begin(at: point(10, true), state: state, renaming: nil)
            drag.update(to: point(195, true))
            drag.reconcile(renamed)
            #expect(drag.active)
            drag.reconcile(changed)
            #expect(!drag.active && drag.source == nil && drag.placement == nil)
            #expect(drag.finish() == nil)
        }
    }

    @Test func onlyTheCurrentOwnerCanRemoveATargetAndRemovalUpdatesIntent() {
        let drag = TabDrag(horizontal: true)
        let state = fixture(drag)
        let first = UUID(), replacement = UUID()
        let bounds = frame(106, true)
        drag.record(.tab("b"), frame: bounds, owner: first)
        drag.record(.tab("b"), frame: bounds, owner: replacement)
        drag.begin(at: point(10, true), state: state, renaming: nil)
        drag.update(to: point(156, true))
        drag.remove(.tab("b"), owner: first)
        #expect(drag.frame(for: .tab("b")) == bounds)
        #expect(drag.placement == .insert("b", after: false, outside: false))
        drag.remove(.tab("b"), owner: replacement)
        #expect(drag.frame(for: .tab("b")) == nil)
        #expect(drag.placement == nil)
        drag.cancel()
        drag.begin(at: point(120, true), state: state, renaming: nil)
        #expect(!drag.active, "a disappeared row cannot be a source")
        drag.record(.tab("a"), frame: frame(0, true), owner: first)
        drag.begin(at: point(10, true), state: state, renaming: nil)
        drag.remove(.tab("a"), owner: first)
        #expect(!drag.active, "hiding the source cancels its gesture")
    }

    @Test(arguments: [false, true]) func scrollingAndNewGeometryDoNotRetainFrozenTargets(horizontal: Bool) {
        let drag = TabDrag(horizontal: horizontal)
        let state = fixture(drag)
        let owner = UUID()
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        drag.update(to: point(195, horizontal))
        #expect(drag.placement == .insert("b", after: true, outside: false))
        drag.scrolled(to: offset(106, horizontal))
        #expect(drag.placement == .insert("c", after: true, outside: false))
        #expect(drag.frame(for: .tab("c")) == frame(106, horizontal))
        drag.record(.tab("c"), frame: frame(106, horizontal), owner: owner)
        drag.scrolled(to: offset(212, horizontal))
        drag.scrolled(to: offset(212, horizontal))
        #expect(drag.frame(for: .tab("c")) == frame(0, horizontal))
        drag.update(to: point(75, horizontal))
        #expect(drag.placement == .insert("c", after: true, outside: false))
        drag.record(.tab("c"), frame: frame(106, horizontal), owner: owner)
        #expect(drag.placement == nil, "new geometry replaces the old hit area")
        drag.update(to: point(110, horizontal))
        #expect(drag.placement == .insert("c", after: false, outside: false))
        drag.remove(.tab("c"), owner: owner)
        #expect(drag.placement == nil)
        #expect(drag.finish() == nil)
    }

    @Test func disappearingHeadersAndEmptyFramesCannotRemainDestinations() {
        let drag = TabDrag(horizontal: true)
        _ = fixture(drag)
        let state = Wire.State(items: [.tab(tab("a")), .group(.init(id: "g", name: "Work", tabs: [tab("b"), tab("c")]))])
        let owner = UUID()
        drag.record(.group("g"), frame: frame(318, true), owner: owner)
        drag.begin(at: point(10, true), state: state, renaming: nil)
        drag.update(to: point(350, true))
        #expect(drag.placement == .intoGroup("g"))
        drag.remove(.group("g"), owner: owner)
        #expect(drag.placement == nil)
        drag.record(.end, frame: frame(318, true), owner: owner)
        #expect(drag.placement == .end)
        drag.record(.end, frame: .zero, owner: owner)
        #expect(drag.frame(for: .end) == nil && drag.placement == nil)
        #expect(drag.finish() == nil)
    }

    @Test(arguments: [false, true]) func edgeScrollingRequiresAnActivePointerInsideTheViewport(horizontal: Bool) {
        let drag = TabDrag(horizontal: horizontal)
        let state = fixture(drag)
        let size = CGSize(width: 400, height: 400)
        drag.begin(at: point(10, horizontal), state: state, renaming: nil)
        #expect(drag.scrollStep(in: size) == -7)
        drag.update(to: point(390, horizontal))
        #expect(drag.scrollStep(in: size) == 7)
        drag.update(to: point(200, horizontal))
        #expect(drag.scrollStep(in: size) == 0)
        drag.update(to: point(410, horizontal))
        #expect(drag.scrollStep(in: size) == 0)
        drag.update(to: horizontal ? CGPoint(x: 390, y: -1) : CGPoint(x: -1, y: 390))
        #expect(drag.scrollStep(in: size) == 0)
        drag.cancel()
        #expect(drag.scrollStep(in: size) == 0)
    }

    /// Register fixed server-order rows in either strip orientation.
    private func fixture(_ drag: TabDrag) -> Wire.State {
        for (i, id) in ["a", "b", "c"].enumerated() {
            drag.record(.tab(id), frame: frame(CGFloat(i * 106), drag.horizontal))
        }
        return Wire.State(items: ["a", "b", "c"].map { .tab(tab($0)) })
    }

    private func tab(_ id: String) -> Wire.TabInfo { .init(id: id, panes: [], layout: .pane(id)) }
    private func point(_ coordinate: CGFloat, _ horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: coordinate, y: 17) : CGPoint(x: 30, y: coordinate)
    }
    private func frame(_ coordinate: CGFloat, _ horizontal: Bool) -> CGRect {
        horizontal ? CGRect(x: coordinate, y: 0, width: 100, height: 34)
                   : CGRect(x: 0, y: coordinate, width: 200, height: 100)
    }
    private func offset(_ coordinate: CGFloat, _ horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: coordinate, y: 0) : CGPoint(x: 0, y: coordinate)
    }
}

@MainActor extension SessionTests {
    /// Escape is consumed only by an explicitly supplied source window.
    /// Headless gestures neither intercept keys nor infer a key window.
    @Test func tabDragEscapeBelongsToItsExplicitSourceWindow() throws {
        let first = dragWindow(), second = dragWindow()
        defer { first.close(); second.close() }
        let drag = TabDrag(horizontal: true)
        let state = Wire.State(items: [.tab(.init(id: "a", panes: [], layout: .pane("a")))])
        drag.record(.tab("a"), frame: CGRect(x: 0, y: 0, width: 100, height: 34))
        drag.begin(at: CGPoint(x: 10, y: 10), state: state, renaming: nil, window: first)
        NSApp.sendEvent(try dragEscape(in: second))
        #expect(drag.active)
        NSApp.sendEvent(try dragEscape(in: first))
        #expect(!drag.active && drag.source == nil)
        drag.update(to: CGPoint(x: 80, y: 10))
        #expect(drag.finish() == nil)
        drag.begin(at: CGPoint(x: 10, y: 10), state: state, renaming: nil)
        NSApp.sendEvent(try dragEscape(in: first))
        #expect(drag.active)
        drag.cancel()
    }

    /// A different window resigning cannot cancel this strip's gesture.
    @Test func tabDragCancelsOnlyWhenItsSourceWindowResigns() {
        let first = dragWindow(), second = dragWindow()
        defer { first.close(); second.close() }
        let drag = TabDrag(horizontal: true)
        let state = Wire.State(items: [.tab(.init(id: "a", panes: [], layout: .pane("a")))])
        drag.record(.tab("a"), frame: CGRect(x: 0, y: 0, width: 100, height: 34))
        drag.begin(at: CGPoint(x: 10, y: 10), state: state, renaming: nil, window: first)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
        #expect(drag.active)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        #expect(!drag.active && drag.source == nil && drag.placement == nil)
        #expect(drag.finish() == nil)
    }

    /// Keep window fixtures offscreen; events below stay within this process.
    private func dragWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func dragEscape(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }
}

