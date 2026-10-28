import AppKit
import Testing
@testable import Koi

@MainActor extension SessionTests {
    /// Shift reserves the whole drag for selection, including release after
    /// Shift is let go, even when the program enables SGR mouse tracking.
    @Test func shiftDragSelectsInsideMouseTrackingPrograms() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(pane: "selection", at: .local)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        let state = VTTerminal(cols: 80, rows: 24)
        state.write(Array("hello world\u{1b}[?1000h\u{1b}[?1006h".utf8))
        #expect(view.restoreTerminal(from: state.snapshot()))
        let cell = CGFloat(view.currentGridSize.cellWidth) / window.backingScaleFactor
        let height = CGFloat(view.currentGridSize.cellHeight) / window.backingScaleFactor
        func event(_ type: NSEvent.EventType, x: CGFloat, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            let local = NSPoint(x: view.padding + x * cell, y: view.padding + height * 0.5)
            return try #require(NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil),
                modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, x: 0.1, modifiers: .shift))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 5.0, modifiers: []))
        view.mouseUp(with: try event(.leftMouseUp, x: 5.0, modifiers: []))
        #expect(view.terminal?.selectedText() == "hello")
        #expect(view.accessibilitySelectedText() == "hello")
        #expect(view.accessibilityString(for: view.accessibilitySelectedTextRange()) == "hello")

        // IME ranges refer only to marked input; AX selection stays on output.
        view.setMarkedText("日本", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.selectedRange() == NSRange(location: 1, length: 0))
        #expect(view.markedRange() == NSRange(location: 0, length: 2))
        #expect(view.accessibilitySelectedText() == "hello")
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(view.selectedRange().location == NSNotFound)
        #expect(view.accessibilitySelectedText() == "")
        #expect(view.accessibilitySelectedTextRange().length == 0)
        view.setMarkedText("unfinished", selectedRange: NSRange(location: 10, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setFocused(false)
        #expect(!view.hasMarkedText())
    }

    /// A display link targets its view strongly; removing a pane must break
    /// that lifetime so closed panes and their native terminals are released.
    @Test func removingAPaneReleasesItsDisplayLinkAndTerminal() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        weak var released: TerminalView?
        autoreleasepool {
            let view = TerminalView(pane: "lifetime", at: .local)
            released = view
            window.contentView = view
            _ = view.restoreTerminal(from: VTTerminal(cols: 80, rows: 24).snapshot())
            window.contentView = nil
        }
        #expect(released == nil)
    }
}

/// Newlines in a bracketed paste stay inside one input block. Unsafe control
/// bytes cannot terminate that block or act as terminal commands.
@Test @MainActor func multilinePasteFollowsTheCurrentModeAndSanitizesControlBytes() {
    let text = "first\n  日本語\nlast"
    let bracketed = TerminalView.pasteBytes(text, bracketed: true)
    #expect(bracketed == Array(("\u{1b}[200~" + text + "\u{1b}[201~").utf8))
    #expect(TerminalView.pasteBytes(text, bracketed: false) == Array("first\r  日本語\rlast".utf8))
    let injection = "a\0\u{03}\u{1b}[201~b"
    #expect(TerminalView.pasteBytes(injection, bracketed: true) == Array("\u{1b}[200~a   [201~b\u{1b}[201~".utf8))
    #expect(TerminalView.pasteBytes("", bracketed: true).isEmpty)
}

/// Text pastes from wherever on the pasteboard it is: a launcher such as
/// Raycast puts it in a later item beside other types it recorded, and
/// some apps put it under a plain-text type other than the standard one.
@Test @MainActor func pasteFindsTextBesideOtherTypes() {
    let board = NSPasteboard(name: .init("koi.tests.paste"))
    board.clearContents()
    let picture = NSPasteboardItem()
    picture.setData(Data([0, 1, 2]), forType: .tiff)
    let text = NSPasteboardItem()
    text.setString("from raycast", forType: .string)
    board.writeObjects([picture, text])
    #expect(TerminalView.pasteText(on: board) == "from raycast")

    board.clearContents()
    let plain = NSPasteboardItem()
    plain.setString("plain", forType: .init("public.plain-text"))
    board.writeObjects([plain])
    #expect(TerminalView.pasteText(on: board) == "plain")

    board.clearContents()
    #expect(TerminalView.pasteText(on: board) == nil)
}

/// Copied files paste as their paths, quoted for the shell.
@Test @MainActor func pasteTypesCopiedFilesAsPaths() {
    let board = NSPasteboard(name: .init("koi.tests.paste-files"))
    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/a b") as NSURL, URL(fileURLWithPath: "/tmp/c") as NSURL])
    #expect(TerminalView.pasteText(on: board) == "'/tmp/a b' /tmp/c")
}
