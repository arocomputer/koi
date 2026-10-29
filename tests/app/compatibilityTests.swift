import AppKit
import GhosttyVt
import Testing
@testable import Koi

// Synthetic OpenCode-like output, not a recording from OpenCode or a user session.
// Keep AppKit and theme-dependent VT fixtures in the shared serialized suite.
@MainActor extension SessionTests {
    /// Shift owns the drag through release in a mouse-reporting alternate screen;
    /// Command-C invokes TerminalView.copy with a private clipboard destination.
    @Test func compatibilityMouseSelectionAndCommandCopy() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(pane: "compatibility-selection", at: .local)
        window.contentView = view
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu; window.contentView = nil; window.close() }
        let source = VTTerminal(cols: 80, rows: 24)
        source.write(Array("shell$ \u{1b}[?1049h\u{1b}[H\u{1b}[?1000h\u{1b}[?1006hanswer 日本語".utf8))
        #expect(view.restoreTerminal(from: source.snapshot()))
        let terminal = try #require(view.terminal)
        #expect(terminal.isAlternateScreen && terminal.mode(1000) && terminal.mode(1006))
        let cell = CGFloat(view.currentGridSize.cellWidth) / window.backingScaleFactor
        let height = CGFloat(view.currentGridSize.cellHeight) / window.backingScaleFactor
        // Build fixture mouse coordinates without sending events to the desktop.
        func mouse(_ type: NSEvent.EventType, _ column: CGFloat, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            let point = NSPoint(x: view.padding + column * cell, y: view.padding + height * 0.5)
            return try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, 0.1, .shift))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 6, []))
        view.mouseUp(with: try mouse(.leftMouseUp, 6, []))
        #expect(terminal.selectedText() == "answer")

        let board = NSPasteboard(name: .init("koi.tests.compatibility-copy.\(UUID())"))
        defer { board.releaseGlobally() }
        view.clipboardWriter = { text in
            board.clearContents()
            return board.setString(text, forType: .string)
        }
        let menu = NSMenu()
        let root = NSMenuItem()
        let submenu = NSMenu()
        root.submenu = submenu
        menu.addItem(root)
        let item = NSMenuItem(title: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        item.keyEquivalentModifierMask = .command
        item.target = view
        submenu.addItem(item)
        NSApp.mainMenu = menu
        #expect(window.makeFirstResponder(view))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(view.performKeyEquivalent(with: key))
        #expect(board.string(forType: .string) == "answer")
        #expect(terminal.selectedText() == "answer")
    }

    /// Reattachment keeps paste framing; leaving the TUI returns to shell CRs.
    @Test func compatibilityPrivatePasteFollowsRestoredModes() throws {
        let board = NSPasteboard(name: .init("koi.tests.compatibility-paste.\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("explain 日本語\n  next", forType: .string)
        let text = try #require(TerminalView.pasteText(on: board))
        let source = VTTerminal(cols: 40, rows: 6)
        source.write(Array("\u{1b}[?1049h\u{1b}[?2004h".utf8))
        let mirror = try #require(VTTerminal(snapshot: source.snapshot()))
        #expect(TerminalView.pasteBytes(text, bracketed: mirror.mode(2004))
            == Array("\u{1b}[200~explain 日本語\n  next\u{1b}[201~".utf8))
        mirror.write(Array("\u{1b}[?2004l\u{1b}[?1049l".utf8))
        #expect(TerminalView.pasteBytes(text, bracketed: mirror.mode(2004))
            == Array("explain 日本語\r  next".utf8))
    }

    /// Render-state colors and grapheme addresses survive mirror restoration.
    /// This inspects CPU render data; no renderer or Metal device is created.
    @Test func compatibilityColorsAndUnicodeCellsSurviveSnapshot() throws {
        let source = VTTerminal(cols: 30, rows: 4)
        source.write(Array("\u{1b}[?1049h\u{1b}[38;2;18;52;86;48;5;196m界e\u{301}🐟!\u{1b}[0m".utf8))
        let mirror = try #require(VTTerminal(snapshot: source.snapshot()))
        for terminal in [source, mirror] {
            #expect(terminal.text(x: 0, y: 0) == "界")
            #expect(terminal.text(x: 2, y: 0) == "e\u{301}")
            #expect(terminal.text(x: 3, y: 0) == "🐟")
            #expect(terminal.text(x: 5, y: 0) == "!")
            #expect(terminal.cursor.x == 6)
            terminal.select(from: (0, 0), to: (5, 0))
            #expect(terminal.selectedText() == "界e\u{301}🐟!")
            terminal.clearSelection()
            try compatibilityCheckFirstCellColors(terminal)
        }
    }

    /// A resized, reattached TUI can exit to the saved primary screen and cursor.
    @Test func compatibilityResizeAndSnapshotRestoreTheShell() throws {
        let source = VTTerminal(cols: 30, rows: 6)
        source.write(Array("previous output\r\nshell$ \u{1b}[?1049h\u{1b}[?25l\u{1b}[2J\u{1b}[Hsynthetic answer".utf8))
        source.resize(GridSize(cols: 40, rows: 8, cellWidth: 8, cellHeight: 16))
        let mirror = try #require(VTTerminal(snapshot: source.snapshot()))
        #expect(mirror.size.cols == 40 && mirror.size.rows == 8)
        #expect(mirror.isAlternateScreen && !mirror.cursorVisible)
        #expect(mirror.text().contains("synthetic answer"))
        mirror.write(Array("\u{1b}[?25h\u{1b}[?1049lready".utf8))
        #expect(!mirror.isAlternateScreen && mirror.cursorVisible)
        #expect(mirror.text() == "previous output\nshell$ ready")
        #expect(mirror.cursor.x == 12 && mirror.cursor.y == 1)
        #expect(!mirror.text().contains("synthetic answer"))
    }
}

/// Uses the same CPU render-state API as Renderer to check resolved SGR colors.
private func compatibilityCheckFirstCellColors(_ terminal: VTTerminal) throws {
    var state: GhosttyRenderState?
    var iterator: GhosttyRenderStateRowIterator?
    var cells: GhosttyRenderStateRowCells?
    ghostty_render_state_new(nil, &state)
    ghostty_render_state_row_iterator_new(nil, &iterator)
    ghostty_render_state_row_cells_new(nil, &cells)
    defer {
        if let cells { ghostty_render_state_row_cells_free(cells) }
        if let iterator { ghostty_render_state_row_iterator_free(iterator) }
        if let state { ghostty_render_state_free(state) }
    }
    let render = try #require(state)
    #expect(ghostty_render_state_update(render, terminal.raw) == GHOSTTY_SUCCESS)
    ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)
    try #require(ghostty_render_state_row_iterator_next(iterator))
    ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
    try #require(ghostty_render_state_row_cells_next(cells))
    var foreground = GhosttyColorRgb()
    var background = GhosttyColorRgb()
    #expect(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground) == GHOSTTY_SUCCESS)
    #expect(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background) == GHOSTTY_SUCCESS)
    #expect(foreground.r == 18 && foreground.g == 52 && foreground.b == 86)
    #expect(background.r == 255 && background.g == 0 && background.b == 0)
}
