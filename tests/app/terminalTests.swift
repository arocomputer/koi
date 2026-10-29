import AppKit
import Testing
@testable import Koi

/// A broken mirror or unavailable attachment is not proof that its shell died.
@MainActor @Test func attachmentFailuresPreserveTheProcessOutcomeAndLastScreen() {
    let view = TerminalView(pane: "recovery-fixture", at: .local)
    let terminal = VTTerminal(cols: 40, rows: 4)
    terminal.write(Array("work still running".utf8))
    view.handle([.snapshot(terminal.snapshot())])
    var exits = 0
    view.onEnd = { exits += 1 }
    view.handle([.snapshot([0, 1, 2])])
    #expect(exits == 0)
    #expect(view.connectionDescription.contains("invalid terminal snapshot"))
    #expect(view.terminal?.text().contains("work still running") == true)
    view.handle([.failure("incompatible snapshot format")])
    #expect(exits == 0 && view.connectionDescription.hasPrefix("Connection error"))
    view.handle([.exited(-1)])
    #expect(exits == 0)
    view.handle([.exited(0)])
    #expect(exits == 1 && view.connectionDescription == "Ended")
}

/// Merely creating a view of another device grants no typing/resize permission.
@MainActor @Test func remoteMirrorsStartPassiveAndOwnershipIsExplicit() {
    let view = TerminalView(pane: "observer-fixture", at: .ssh("fixture.invalid"))
    #expect(view.observing && !view.canControl)
    view.handle([.negotiated(ownership: true, observing: true)])
    view.handle([.snapshot(VTTerminal(cols: 40, rows: 4).snapshot()), .ownership(false)])
    #expect(view.observing && view.connectionDescription.hasPrefix("Observing"))
    view.handle([.ownership(true)])
    #expect(!view.observing && view.connectionDescription == "Connected")
    view.handle([.ownership(false)])
    #expect(view.observing && view.connectionDescription.hasPrefix("Observing"))
    view.detach()
}

/// ⌘-click only opens real web and mail links, and only the one under the
/// pointer.
@MainActor @Test func findsTheUrlUnderTheClick() {
    let line = "see https://example.com/path and foo@bar.com here"
    // Inside the https URL.
    #expect(TerminalView.url(in: line, at: 10)?.absoluteString == "https://example.com/path")
    // Inside the email.
    #expect(TerminalView.url(in: line, at: 36)?.scheme == "mailto")
    // On plain text.
    #expect(TerminalView.url(in: line, at: 0) == nil)
    // A bare word that isn't a link.
    #expect(TerminalView.url(in: "just some words", at: 5) == nil)
    #expect(TerminalView.url(in: "ftp://example.com/file", at: 8) == nil)
}

/// A view that is not laid out yet has no grid to offer: attaching with a
/// placeholder 2x1 would resize the shell twice before it ever drew.
@MainActor @Test func fitOffersNoGridUntilTheViewHasRoom() {
    func fit(_ w: CGFloat, _ h: CGFloat) -> GridSize? {
        TerminalView.fit(points: CGSize(width: w, height: h), scale: 2, padding: 12, cellWidth: 16, cellHeight: 32)
    }
    #expect(fit(0, 0) == nil)
    #expect(fit(30, 30) == nil)
    // 800x600 points at 2x, minus 24 px padding per side: 1552x1152 px.
    let size = fit(800, 600)
    #expect(size?.cols == 97)
    #expect(size?.rows == 36)
    #expect(size?.cellWidth == 16)
    #expect(size?.cellHeight == 32)
}

/// The empty-shell cursor is held back only on the first snapshot, until the
/// shell speaks or the user types, however slowly the shell starts; a
/// restored screen with content is never held back.
@MainActor @Test func emptyShellCursorWaitsForTheShellOrTheUser() async throws {
    let view = TerminalView(pane: "cursor-test", at: .local)
    let blank = VTTerminal(cols: 20, rows: 2).snapshot()
    #expect(view.restoreTerminal(from: blank))
    #expect(view.cursorSuppressed)
    try await Task.sleep(for: .milliseconds(200))
    #expect(view.cursorSuppressed, "a slow shell does not get a cursor on an empty screen")
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    view.keyDown(with: key)
    #expect(!view.cursorSuppressed)
    // A later snapshot (a reconnect) is never suppressed.
    #expect(view.restoreTerminal(from: blank))
    #expect(!view.cursorSuppressed)

    let fresh = TerminalView(pane: "content-test", at: .local)
    let content = VTTerminal(cols: 20, rows: 2)
    content.write(Array("$ ".utf8))
    #expect(fresh.restoreTerminal(from: content.snapshot()))
    #expect(!fresh.cursorSuppressed)
}

@MainActor extension SessionTests {
    /// Native AX text getters expose history, viewport, UTF-16 navigation and
    /// the cursor after trailing spaces, and invalidate on snapshot replacement.
    @Test func accessibilityReadsTerminalHistoryAndCursor() throws {
        let view = TerminalView(pane: "accessibility", at: .local)
        let state = VTTerminal(cols: 20, rows: 2)
        state.write(Array("old\r\nrepeat\r\nrepeat 🐟\r\n$ ".utf8))
        #expect(view.restoreTerminal(from: state.snapshot()))
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        let text = try #require(view.accessibilityValue() as? String)
        #expect(text == "old\nrepeat\nrepeat 🐟\n$ ")
        #expect(view.accessibilityNumberOfCharacters() == (text as NSString).length)
        #expect(view.accessibilityString(for: view.accessibilityVisibleCharacterRange()) == "repeat 🐟\n$ ")
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: (text as NSString).length, length: 0))
        #expect(view.accessibilityInsertionPointLineNumber() == 3)
        #expect(view.accessibilityString(for: view.accessibilityRange(forLine: 2)) == "repeat 🐟")
        #expect(view.accessibilityLine(for: 18) == 2)
        #expect(view.accessibilityRange(for: 19) == NSRange(location: 18, length: 2))
        #expect(view.accessibilityString(for: NSRange(location: Int.max, length: 1)) == nil)
        #expect(view.accessibilityString(for: NSRange(location: NSNotFound, length: 0)) == nil)
        #expect(!view.isAccessibilitySelectorAllowed(#selector(NSView.setAccessibilityValue(_:))))

        state.write(Array("🐟e\u{301}".utf8))
        state.scroll(rows: -2)
        #expect(view.restoreTerminal(from: state.snapshot()))
        // Snapshots may restore the active viewport; the AX document still
        // contains history and the updated cursor in the same UTF-16 space.
        #expect((view.accessibilityValue() as? String)?.hasSuffix("$ 🐟e\u{301}") == true)
        #expect(view.accessibilitySelectedTextRange() == NSRange(location: 27, length: 0))
    }

    /// Shell paths are explicit on either endpoint; no URL scheme or control
    /// byte can become a command or be silently changed by paste sanitization.
    @Test func pathActionsRejectNonPathsAndPreserveShellWords() {
        #expect(TerminalView.shellPath(URL(string: "https://example.com/tmp")!) == nil)
        #expect(TerminalView.shellPath(URL(string: "file://other-host/tmp/a")!) == nil)
        #expect(TerminalView.shellPath(URL(fileURLWithPath: "/tmp/a\nb")) == nil)
        let path = TerminalView.shellPath(URL(fileURLWithPath: "/tmp/a b's"))
        #expect(path == "/tmp/a b's")
        #expect(path.map(TerminalView.shellQuoted) == "'/tmp/a b'\\''s'")
        #expect(TerminalView.shellQuoted("/Users/me/repos/koi") == "/Users/me/repos/koi")
    }
}

/// Selection ranges use native endpoints rather than a substring lookup;
/// repeated output and wide/combining cells must keep their actual addresses.
@Test func accessibilityMapsNativeSelectionAndScrolledViewport() {
    let terminal = VTTerminal(cols: 20, rows: 2)
    terminal.write(Array("repeat\r\nrepeat\r\nrepeat 🐟e\u{301}\r\n$ ".utf8))
    terminal.select(from: (col: 9, row: 0), to: (col: 7, row: 0))
    var document = TerminalAccessibilityText(terminal)
    #expect(document.selectedText == "🐟e\u{301}")
    #expect(document.selectedRange == NSRange(location: 21, length: 4))
    #expect(document.text.substring(with: document.selectedRange) == "🐟e\u{301}")
    #expect(document.range(row: 2, column: 7, terminal: terminal) == NSRange(location: 21, length: 2))
    #expect(document.range(row: 2, column: 8, terminal: terminal) == NSRange(location: 21, length: 2))
    #expect(document.column(for: 23, row: 2, terminal: terminal, trailing: true) == 9)
    #expect(document.range(row: 2, column: 16, terminal: terminal).length == 0)
    terminal.scroll(rows: -2)
    document = TerminalAccessibilityText(terminal)
    #expect(document.text.substring(with: document.visible) == "repeat\nrepeat")
    #expect(document.selectedRange == NSRange(location: 21, length: 4))
}
