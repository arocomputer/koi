import Foundation

/// Instant typing for remote panes.
///
/// A keystroke to another machine takes a round trip before its echo comes
/// back. The predictor shows the expected result at once as an overlay on
/// the pane's own grid: the typed character at the caret, or the erased cell
/// for Backspace, with the cursor moved along. Nothing is written into the
/// terminal, so a wrong guess can never corrupt the screen; when the real
/// output arrives the overlay is checked against it, cell by cell, and
/// anything confirmed or contradicted disappears.
///
/// Completed echoes establish confidence. Reconnects, program changes and
/// unpredictable input clear it; unconfirmed typing stays hidden while the
/// predictor learns whether the application is echoing again.
struct Prediction {
    struct Cell: Equatable {
        var x: UInt16
        var y: UInt16
        var text: String
    }

    /// What the renderer draws over the grid.
    struct Overlay: Equatable {
        var cells: [Cell] = []
        /// Where the cursor shows while predictions are pending.
        var caret: (x: UInt16, y: UInt16)?

        static func == (a: Overlay, b: Overlay) -> Bool {
            a.cells == b.cells && a.caret?.x == b.caret?.x && a.caret?.y == b.caret?.y
        }
    }

    private struct Pending {
        var cell: Cell
        /// The cell contents expected before this prediction takes effect.
        var original: String
        var at: Date
        var erase: Bool
        /// An erase over an already blank cell must first observe its letter.
        var needsOriginal: Bool = false
        /// Earlier unobserved states of this cell, in input order.
        var intermediate: [String] = []
    }

    private var pending: [Pending] = []
    /// Where the next typed character goes, while predictions are pending.
    private var caret: (x: UInt16, y: UInt16)?
    /// Characters typed since the last key whose effect was unforeseeable;
    /// Backspace is predicted only over those.
    private var typed = 0
    /// Echoes have been matching, so predictions are shown as they are made.
    private var confident = false
    /// The program in front, as the server reports it; an empty value is a
    /// foreground shell, which still must demonstrate echo.
    private(set) var program = ""
    private var srtt: TimeInterval = 0.1
    /// After the last prediction is confirmed, the cursor keeps showing at
    /// the caret until the terminal's cursor gets there too (an erase echoes
    /// as backspace, space, backspace, and the bytes may arrive apart), or
    /// until this time.
    private var settleUntil: Date?

    var overlay: Overlay {
        confident ? Overlay(cells: pending.map(\.cell), caret: caret) : Overlay()
    }

    var isActive: Bool { !pending.isEmpty || settleUntil != nil }

    mutating func setProgram(_ program: String) {
        guard program != self.program else { return }
        self.program = program
        // A new program in front: what it does with keys is unknown.
        pending.removeAll()
        caret = nil
        typed = 0
        settleUntil = nil
        confident = false
    }

    /// Everything is forgotten: the pane reattached or resized.
    mutating func reset() {
        pending.removeAll()
        caret = nil
        typed = 0
        confident = false
        settleUntil = nil
    }

    /// Track narrow input; guesses stay hidden until a real echo establishes confidence.
    mutating func typed(_ text: String, in terminal: VTTerminal, now: Date = Date()) {
        guard !terminal.mode(2026), text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
              Self.isNarrow(scalar),
              let at = nextCaret(in: terminal) else {
            other()
            return
        }
        settleUntil = nil
        let previous = pending.last { $0.cell.x == at.x && $0.cell.y == at.y }
        let intermediate = previous.map { $0.intermediate + [$0.cell.text] } ?? []
        guard intermediate.count <= 16, pending.count < 256 else { other(); return }
        let original = previous?.original ?? terminal.text(x: at.x, y: at.y)
        pending.removeAll { $0.cell.x == at.x && $0.cell.y == at.y }
        pending.append(Pending(cell: Cell(x: at.x, y: at.y, text: text), original: original, at: now,
                               erase: false, intermediate: intermediate))
        caret = (at.x + 1, at.y)
        typed += 1
    }

    /// Predict an erase only for characters typed since the last unsafe key.
    mutating func backspace(in terminal: VTTerminal, now: Date = Date()) {
        guard !terminal.mode(2026), typed > 0, let at = nextCaret(in: terminal), at.x > 0 else {
            other()
            return
        }
        settleUntil = nil
        typed -= 1
        let x = at.x - 1
        let shown = terminal.text(x: x, y: at.y)
        let previous = pending.last { $0.cell.x == x && $0.cell.y == at.y }
        let intermediate = previous.map { $0.intermediate + [$0.cell.text] } ?? []
        guard intermediate.count <= 16, pending.count < 256 else { other(); return }
        pending.removeAll { $0.cell.x == x && $0.cell.y == at.y }
        // Keep covering an in-flight character until its erase is observed.
        let original = previous?.original ?? shown
        pending.append(Pending(cell: Cell(x: x, y: at.y, text: " "), original: original, at: now, erase: true,
                               needsOriginal: Self.same(shown, " "), intermediate: intermediate))
        caret = (at.x - 1, at.y)
    }

    /// Enter was sent: what follows may be a password prompt or output, so
    /// nothing is shown until an echo matches again.
    mutating func entered() {
        other()
    }

    /// A key whose effect cannot be foreseen (arrows, control keys, paste).
    mutating func other() {
        pending.removeAll()
        caret = nil
        settleUntil = nil
        typed = 0
        confident = false
    }

    /// Check completed output; held redraws discard predictions based on the live grid.
    mutating func reconcile(with terminal: VTTerminal, now: Date = Date()) {
        expire(now: now)
        guard !terminal.mode(2026) else { other(); return }
        let cursor = terminal.cursor
        guard !pending.isEmpty else {
            if settleUntil != nil { settle(cursor: cursor, now: now) }
            return
        }
        var contradicted = false
        var remaining: [Pending] = []
        for var p in pending {
            let shown = terminal.text(x: p.cell.x, y: p.cell.y)
            if !Self.same(shown, p.original),
               let index = p.intermediate.firstIndex(where: { Self.same(shown, $0) }) {
                p.intermediate.removeFirst(index + 1)
                p.original = shown
                p.needsOriginal = false
                remaining.append(p)
                continue
            }
            if p.needsOriginal {
                if !Self.same(shown, " ") { p.needsOriginal = false }
                remaining.append(p)
                continue
            }
            if Self.same(shown, p.cell.text) {
                // An unchanged cell needs cursor movement as evidence of echo.
                if !p.erase && Self.same(p.original, p.cell.text) &&
                    (cursor.y != p.cell.y || cursor.x <= p.cell.x) {
                    remaining.append(p)
                    continue
                }
                srtt = srtt * 0.8 + max(0, now.timeIntervalSince(p.at)) * 0.2
                confident = true
                continue
            }
            if Self.same(shown, p.original) ||
                (Self.same(shown, " ") && cursor.y == p.cell.y && cursor.x <= p.cell.x && caret != nil) {
                remaining.append(p)
                continue
            }
            confident = false
            contradicted = true
        }
        if contradicted {
            other()
            confident = false
            return
        }
        pending = remaining
        if pending.isEmpty { settle(cursor: cursor, now: now) }
    }

    /// With nothing pending, the caret stays until the cursor reaches it.
    private mutating func settle(cursor: (x: UInt16, y: UInt16), now: Date) {
        guard let c = caret, c.x != cursor.x || c.y != cursor.y else {
            caret = nil
            settleUntil = nil
            return
        }
        if settleUntil == nil { settleUntil = now.addingTimeInterval(0.15) }
    }

    /// Drop the whole speculative state when an echo misses its deadline.
    mutating func expire(now: Date = Date()) {
        if let until = settleUntil, now >= until {
            settleUntil = nil
            caret = nil
        }
        guard !pending.isEmpty else { return }
        let timeout = min(max(srtt * 3, 0.25), 2)
        if pending.contains(where: { now.timeIntervalSince($0.at) >= timeout }) {
            other()
            confident = false
        }
    }

    /// Use the predicted caret while pending or settling, else the terminal cursor.
    private func nextCaret(in terminal: VTTerminal) -> (x: UInt16, y: UInt16)? {
        guard terminal.viewportIsActive, !terminal.isAlternateScreen || terminal.cursorVisible else { return nil }
        let cursor = terminal.cursor
        if !pending.isEmpty || settleUntil != nil {
            guard let caret, caret.y == cursor.y else { return nil }
            return caret.x < terminal.size.cols - 1 ? caret : nil
        }
        guard terminal.cursorVisible, !terminal.cursorPendingWrap, cursor.x < terminal.size.cols - 1 else { return nil }
        return cursor
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        (a.isEmpty ? " " : a) == (b.isEmpty ? " " : b)
    }

    /// Printable and one cell wide: the ranges that are certainly so.
    private static func isNarrow(_ s: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(s.value) || (0xA0...0x24F).contains(s.value)
    }
}
