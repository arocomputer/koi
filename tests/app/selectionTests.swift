import CoreGraphics
import Testing
@testable import Koi

/// The engine owns word, line and pixel selection; these pin what the adapter
/// adds: the geometry, timing and click chaining it forwards, autoscrolling,
/// gesture ending and terminal ownership.
private let geometry = TerminalSelection.Geometry(
    size: CGSize(width: 200, height: 80), cell: CGSize(width: 10, height: 20), padding: 0)

/// The middle of a cell, plus an x offset in pixels.
private func point(_ col: Int, _ row: Int, dx: CGFloat = 5) -> CGPoint {
    CGPoint(x: CGFloat(col) * 10 + dx, y: CGFloat(row) * 20 + 10)
}

@MainActor private func makeSelection(_ text: String, cols: UInt16 = 20, rows: UInt16 = 4) -> TerminalSelection {
    let terminal = VTTerminal(cols: cols, rows: rows)
    terminal.write(Array(text.utf8))
    return TerminalSelection(terminal: terminal)
}

/// Clicks `count` times at a cell, quickly enough to chain, and releases
/// after each.
@MainActor private func click(_ s: TerminalSelection, _ col: Int, _ row: Int, count: Int) {
    for i in 0..<count {
        s.press(at: point(col, row), geometry: geometry, time: 10 + Double(i) * 0.1, repeatInterval: 0.5)
        s.release(at: point(col, row), geometry: geometry)
    }
}

/// Positions, timestamps and the double-click interval reach the engine:
/// quick clicks chain into word and line selection, slow ones start over,
/// and a drag follows the pixel inside a cell rather than the cell.
@MainActor @Test func clicksAndDragsReachTheEngineWithTheirGeometryAndTiming() {
    let s = makeSelection("hello world\r\nsecond line")
    s.terminal.selectAll()
    s.press(at: point(2, 0), geometry: geometry, time: 1, repeatInterval: 0.5)
    #expect(!s.terminal.hasSelection, "a new single press clears the old selection")
    s.release(at: point(2, 0), geometry: geometry)
    click(s, 7, 0, count: 2)
    #expect(s.terminal.selectedText() == "world")
    click(s, 7, 0, count: 3)
    #expect(s.terminal.selectedText() == "hello world")
    s.press(at: point(7, 0), geometry: geometry, time: 20, repeatInterval: 0.5)
    s.release(at: point(7, 0), geometry: geometry)
    s.press(at: point(7, 0), geometry: geometry, time: 21, repeatInterval: 0.5)
    s.release(at: point(7, 0), geometry: geometry)
    #expect(!s.terminal.hasSelection, "a second click after the interval is a new single click")
    s.press(at: point(0, 0, dx: 2), geometry: geometry, time: 30, repeatInterval: 0.5)
    s.drag(at: point(4, 0, dx: 1), geometry: geometry)
    #expect(s.terminal.selectedText() == "hell")
    s.drag(at: point(4, 0, dx: 8), geometry: geometry)
    #expect(s.terminal.selectedText() == "hello")
}

@MainActor @Test func autoscrollExtendsSelectionAndSurvivesOutput() {
    let s = makeSelection((0..<12).map { String(format: "line%02d", $0) }.joined(separator: "\r\n"))
    #expect(s.terminal.viewportIsActive)
    s.press(at: point(0, 3), geometry: geometry, time: 10, repeatInterval: 0.5)
    #expect(!s.autoscrolling)
    s.drag(at: CGPoint(x: 5, y: 0), geometry: geometry)
    #expect(s.autoscrolling)

    #expect(s.autoscroll(geometry: geometry))
    #expect(!s.terminal.viewportIsActive)
    let first = s.terminal.selectedText()
    #expect(first?.hasPrefix("line07") == true)

    // New output must not disturb the selection or the gesture's anchor.
    s.terminal.write(Array("\r\nmore\r\nmore".utf8))
    #expect(s.terminal.selectedText() == first)
    #expect(s.autoscroll(geometry: geometry))
    let second = s.terminal.selectedText()
    #expect(second?.hasPrefix("line06") == true)
    #expect(second?.contains("line10") == true)
}

@MainActor @Test func releaseAndCancelStopAutoscroll() {
    for finish in [
        { (s: TerminalSelection) in s.release(at: CGPoint(x: 5, y: 0), geometry: geometry) },
        { (s: TerminalSelection) in s.cancel() },
    ] {
        let s = makeSelection((0..<12).map { String(format: "line%02d", $0) }.joined(separator: "\r\n"))
        s.press(at: point(0, 3), geometry: geometry, time: 10, repeatInterval: 0.5)
        s.drag(at: CGPoint(x: 5, y: 0), geometry: geometry)
        #expect(s.isActive)
        finish(s)
        #expect(!s.isActive)
        #expect(!s.autoscrolling)
        #expect(!s.autoscroll(geometry: geometry))
        #expect(s.terminal.viewportIsActive)
        let selected = s.terminal.selectedText()
        s.drag(at: point(8, 0), geometry: geometry)
        #expect(s.terminal.selectedText() == selected, "a finished gesture ignores later drags")
    }
}

@MainActor @Test func adapterOwnsTerminalAndFreesGestureFirst() {
    weak var weakTerminal: VTTerminal?
    do {
        let terminal = VTTerminal(cols: 20, rows: 4)
        weakTerminal = terminal
        terminal.write(Array("hello world".utf8))
        var s: TerminalSelection? = TerminalSelection(terminal: terminal)
        s?.press(at: point(2, 0), geometry: geometry, time: 10, repeatInterval: 0.5)
        s?.drag(at: point(6, 0), geometry: geometry)
        // Recreating the adapter mid-gesture (as on a snapshot) is safe.
        s = TerminalSelection(terminal: terminal)
        s?.press(at: point(2, 0), geometry: geometry, time: 11, repeatInterval: 0.5)
        s = nil
        terminal.write(Array("\r\nmore".utf8))
    }
    #expect(weakTerminal == nil)

    // The adapter alone keeps the terminal alive until it is released.
    var s: TerminalSelection? = makeSelection("hello")
    weak var kept: VTTerminal?
    kept = s?.terminal
    s?.press(at: point(1, 0), geometry: geometry, time: 10, repeatInterval: 0.5)
    #expect(kept != nil)
    s = nil
    #expect(kept == nil)
}
