import AppKit
import SwiftUI
import Testing
@testable import Koi

/// Popup lifecycle checks use private windows and app-local events; they never
/// activate an app or send keystrokes or clicks to the user's screen.
@MainActor extension SessionTests {
    @Test func popupFlipsAndClampsAtWindowEdges() {
        let fixture = Fixture(anchor: NSRect(x: 470, y: 8, width: 28, height: 25))
        defer { fixture.close() }
        fixture.presenter.show()
        let overlay = fixture.root.subviews.last!
        let card = overlay.subviews.first!
        #expect(fixture.window.hasKoiPopup)
        #expect(fixture.root.bounds.contains(card.frame))
        #expect(card.frame.minY > fixture.anchor.frame.minY)
    }

    @Test func outsideClickDismissesWithoutReachingTheTerminal() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.presenter.show()
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 460, y: 270),
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
        #expect(!fixture.window.hasKoiPopup)
        #expect(fixture.dismissals == 1)
        #expect(fixture.root.clicks == 0)
    }

    /// A covered tab's pointer monitor must not open its menu through the pane.
    @Test func secondaryClicksRespectCoverageMasks() throws {
        let fixture = Fixture(anchor: NSRect(x: 220, y: 240, width: 100, height: 30))
        defer {
            if let monitor = fixture.presenter.secondaryClick { NSEvent.removeMonitor(monitor) }
            fixture.close()
        }
        fixture.root.wantsLayer = true
        let mask = CAShapeLayer()
        mask.frame = fixture.root.bounds
        mask.path = CGPath(rect: NSRect(x: 0, y: 0, width: 250, height: 300), transform: nil)
        fixture.root.layer?.mask = mask
        fixture.presenter.watchSecondaryClicks()
        for (x, expected) in [(280.0, false), (230.0, true)] {
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: x, y: 255),
                modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
            #expect(fixture.presenter.isPresented == expected)
        }
    }

    @Test func escapeClosesAndRestoresKeyboardFocus() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.window.makeFirstResponder(fixture.root)
        fixture.presenter.show()
        let focus = InputView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        fixture.root.subviews.last!.addSubview(focus)
        fixture.window.makeFirstResponder(focus)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(event)
        #expect(!fixture.window.hasKoiPopup)
        #expect(fixture.window.firstResponder === fixture.root)
        #expect(fixture.dismissals == 1)
    }

    @Test func aRemovedOriginalResponderFallsBackToTheCurrentPane() {
        let fixture = Fixture()
        defer { fixture.close() }
        let original = InputView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        let replacement = InputView(frame: NSRect(x: 40, y: 0, width: 30, height: 30))
        fixture.root.addSubview(original)
        fixture.root.addSubview(replacement)
        fixture.window.makeFirstResponder(original)
        fixture.presenter.centered = true
        fixture.presenter.fallbackResponder = { replacement }
        fixture.presenter.show()
        original.removeFromSuperview()
        fixture.presenter.dismiss()
        #expect(fixture.window.firstResponder === replacement)
    }

    @Test func arrowNavigationSkipsSeparatorsAndReturnRunsTheSelection() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        var chosen = ""
        fixture.presenter.content = AnyView(PopupMenu(entries: [
            .init(title: "First", action: { chosen = "first" }),
            .divider,
            .init(title: "Second", action: { chosen = "second" }),
        ]))
        fixture.presenter.show()
        fixture.root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        for (code, characters) in [(UInt16(125), "\u{f701}"), (125, "\u{f701}"), (36, "\r")] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            fixture.window.sendEvent(event)
        }
        #expect(chosen == "second")
        #expect(!fixture.window.hasKoiPopup)
    }

    /// Owns an offscreen window and an anchored presentation without a server.
    @MainActor private final class Fixture {
        let window: NSWindow
        let root = InputView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let anchor = PopupAnchor.AnchorView()
        let presenter = PopupAnchor.Coordinator()
        var dismissals = 0

        init(anchor rect: NSRect = NSRect(x: 20, y: 240, width: 100, height: 30)) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            anchor.frame = rect
            root.addSubview(anchor)
            presenter.anchor = anchor
            presenter.content = AnyView(Text("Floating control").frame(width: 220, height: 90))
            presenter.dismissed = { [weak self] in self?.dismissals += 1 }
        }

        func close() {
            presenter.dismiss()
            window.close()
        }
    }

    private final class InputView: NSView {
        var clicks = 0
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }
}

@MainActor extension SessionTests {
    @Test @MainActor func hoverHintsCancelOnExitUseConfiguredKeysAndNeverTakeFocus() async throws {
        let fixture = TooltipFixture()
        let old = Config.current.binds[.toggleSidebar]
        defer { Config.current.binds[.toggleSidebar] = old; fixture.close() }
        Config.current.binds[.toggleSidebar] = Keybind("b", [.command, .shift])
        fixture.hint.hover(true)
        #expect(!fixture.hint.isPresented, "a brief hover must not show a hint")
        fixture.hint.hover(false)
        try await Task.sleep(for: .milliseconds(720))
        #expect(!fixture.hint.isPresented, "leaving cancels the pending hint")
        fixture.hint.hover(true)
        try await fixture.waitForHint()
        #expect(fixture.hint.isPresented)
        #expect(fixture.hint.shortcutSymbols == "⇧⌘B")
        #expect(fixture.window.firstResponder === fixture.root)
        #expect(!fixture.window.hasKoiPopup, "hints are not modal popups")
        let card = try #require(fixture.root.subviews.last)
        #expect(fixture.root.bounds.contains(card.frame))
        #expect(fixture.root.hitTest(NSPoint(x: card.frame.midX, y: card.frame.midY)) === fixture.root,
                "the visible hint must not intercept pointer input")
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: card.frame.midX, y: card.frame.midY), modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(click)
        #expect(!fixture.hint.isPresented)
        #expect(fixture.window.firstResponder === fixture.root)
    }

    @Test @MainActor func openingAMenuCancelsPendingAndVisibleHints() async throws {
        let fixture = TooltipFixture()
        let menu = PopupAnchor.Coordinator()
        menu.anchor = fixture.anchor
        menu.content = AnyView(Text("Menu").frame(width: 180, height: 80))
        defer { menu.dismiss(); fixture.close() }
        fixture.hint.hover(true)
        menu.show()
        try await Task.sleep(for: .milliseconds(720))
        #expect(!fixture.hint.isPresented)
        #expect(fixture.window.hasKoiPopup)
        menu.dismiss()
        fixture.hint.hover(true)
        try await fixture.waitForHint()
        #expect(fixture.hint.isPresented)
        menu.show()
        #expect(!fixture.hint.isPresented)
        #expect(fixture.window.hasKoiPopup)
    }
}

/// Offscreen controls exercise the real delay, dismissal and event routing.
@MainActor private final class TooltipFixture {
    let window: NSWindow
    let root = TooltipInputView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let anchor = NSView(frame: NSRect(x: 355, y: 240, width: 32, height: 32))
    let hint = TooltipAnchor.Coordinator()

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.addSubview(anchor)
        window.makeFirstResponder(root)
        hint.anchor = anchor
        hint.title = "Toggle Sidebar"
        hint.shortcut = .toggleSidebar
    }

    func close() { hint.dismiss(); window.close() }

    /// The real delay runs on the main actor, which may also be drawing other
    /// fixtures. Wait for presentation rather than assuming an exact wake time.
    func waitForHint() async throws {
        for _ in 0..<300 {
            if hint.isPresented { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(hint.isPresented)
    }
}

private final class TooltipInputView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
