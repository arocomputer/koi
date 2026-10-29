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
/// What may be predicted comes from two things the pane knows: which program
/// is in front (the server reports it: a shell at its prompt always echoes,
/// an editor may not), and whether recent echoes matched.
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
        /// What the cell showed when the prediction was made.
        var original: String
        var at: Date
        var erase: Bool
    }

    private var pending: [Pending] = []
    /// Canceled visible guesses still have echoes in flight. Recognize those
    /// old glyphs so they cannot contradict newer typing in the same cell.
    private var superseded: [Pending] = []
    /// One hidden candidate lets an unfamiliar program earn prediction again
    /// after Enter, a reconnect or a mismatch, without painting guessed text.
    private var observation: Pending?
    /// Where the next typed character goes, while predictions are pending.
    private var caret: (x: UInt16, y: UInt16)?
    /// Characters typed since the last key whose effect was unforeseeable;
    /// Backspace is predicted only over those.
    private var typed = 0
    /// Echoes have been matching, so predictions are shown as they are made.
    private var confident = true
    /// The program in front, as the server reports it; "" is a shell at its
    /// prompt.
    private(set) var program = ""
    private var srtt: TimeInterval = 0.1
    /// After the last prediction is confirmed, the cursor keeps showing at
    /// the caret until the terminal's cursor gets there too (an erase echoes
    /// as backspace, space, backspace, and the bytes may arrive apart), or
    /// until this time.
    private var settleUntil: Date?

    /// Programs that edit a line and echo it, so typing into them is
    /// predictable from the first key.
    private static let lineEditors: Set<String> = [
        "claude", "claude-code", "codex", "opencode", "opencode-cli", "opencode-ai",
        "pi", "pi-coding-agent", "aider", "aider-chat", "gemini", "gemini-cli", "amp",
    ]

    var overlay: Overlay {
        Overlay(cells: pending.map(\.cell), caret: caret)
    }

    var isActive: Bool { !pending.isEmpty || !superseded.isEmpty || settleUntil != nil }

    mutating func setProgram(_ program: String) {
        guard program != self.program else { return }
        self.program = program
        // A new program in front: what it does with keys is unknown.
        other()
    }

    /// Everything is forgotten: the pane reattached or resized.
    mutating func reset() {
        other()
        confident = false
    }

    private var showsPredictions: Bool {
        confident || program.isEmpty || Self.lineEditors.contains(program)
    }

    /// A printable character was sent.
    mutating func typed(_ text: String, in terminal: VTTerminal, now: Date = Date()) {
        settleUntil = nil
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
              Self.isNarrow(scalar),
              let at = nextCaret(in: terminal) else {
            other()
            return
        }
        let original = terminal.text(x: at.x, y: at.y)
        guard showsPredictions else {
            // Several keys can precede their first echo over a remote link.
            // Keep the first candidate instead of replacing it at the same
            // still-unmoved server cursor on every key.
            if observation == nil || now.timeIntervalSince(observation!.at) > 2 {
                observation = Pending(cell: Cell(x: at.x, y: at.y, text: text), original: original, at: now, erase: false)
            }
            return
        }
        pending.append(Pending(cell: Cell(x: at.x, y: at.y, text: text), original: original, at: now, erase: false))
        caret = (at.x + 1, at.y)
        typed += 1
    }

    /// Backspace was sent.
    mutating func backspace(in terminal: VTTerminal, now: Date = Date()) {
        settleUntil = nil
        guard showsPredictions, typed > 0, let at = nextCaret(in: terminal), at.x > 0 else {
            other()
            return
        }
        typed -= 1
        // Stop painting a canceled character but remember its delayed echo.
        if let last = pending.last, !last.erase, last.cell.x == at.x - 1, last.cell.y == at.y {
            pending.removeLast()
            superseded.append(last)
            // Coalesced echoes can leave an identical replacement ambiguous.
            // If real text is already underneath it, paint the erase now.
            let shown = terminal.text(x: last.cell.x, y: last.cell.y)
            if !Self.same(shown, " ") {
                pending.append(Pending(cell: Cell(x: last.cell.x, y: last.cell.y, text: " "), original: shown, at: now, erase: true))
            }
            caret = (at.x - 1, at.y)
            return
        }
        let original = terminal.text(x: at.x - 1, y: at.y)
        pending.append(Pending(cell: Cell(x: at.x - 1, y: at.y, text: " "), original: original, at: now, erase: true))
        caret = (at.x - 1, at.y)
    }

    /// Enter was sent: what follows may be a password prompt or output, so
    /// nothing is shown until an echo matches again.
    mutating func entered() {
        other()
        confident = false
    }

    /// Unpredictable input invalidates every outstanding cell and caret;
    /// stale guesses must not cover the application's next redraw.
    mutating func other() {
        pending.removeAll(keepingCapacity: true)
        superseded.removeAll(keepingCapacity: true)
        observation = nil
        caret = nil
        settleUntil = nil
        typed = 0
    }

    /// Checks pending predictions against the terminal after output was
    /// applied to it.
    mutating func reconcile(with terminal: VTTerminal, now: Date = Date()) {
        let cursor = terminal.cursor
        // Backspace's first cursor move is not its completed erase. Keep
        // canceled echoes until the blank and final cursor move both arrive.
        superseded.removeAll { p in
            Self.same(terminal.text(x: p.cell.x, y: p.cell.y), " ")
                && cursor.y == p.cell.y && cursor.x <= p.cell.x
        }
        if let candidate = observation {
            let shown = terminal.text(x: candidate.cell.x, y: candidate.cell.y)
            if now.timeIntervalSince(candidate.at) > 2 {
                observation = nil
            } else if Self.same(shown, candidate.cell.text), cursor.y == candidate.cell.y, cursor.x > candidate.cell.x {
                confident = true
                observation = nil
            } else if !Self.same(shown, candidate.original) {
                observation = nil
            }
        }
        guard !pending.isEmpty else {
            if superseded.isEmpty {
                settle(cursor: cursor, now: now, atOnce: false)
            }
            return
        }
        var contradicted = false
        pending.removeAll { p in
            let shown = terminal.text(x: p.cell.x, y: p.cell.y)
            // An old identical glyph must not confirm its replacement, and
            // the intermediate erase must not contradict newer typing.
            if superseded.contains(where: {
                $0.cell.x == p.cell.x && $0.cell.y == p.cell.y
                    && (Self.same(shown, $0.cell.text) || Self.same(shown, " "))
            }) { return false }
            if Self.same(shown, p.cell.text) {
                // Confirmed; learn how long the echo took.
                srtt = srtt * 0.8 + now.timeIntervalSince(p.at) * 0.2
                confident = true
                return true
            }
            if Self.same(shown, p.original) { return false }
            // Blanked ahead of the server's cursor: a program that redraws
            // its whole input line on each key has not reached it yet.
            if Self.same(shown, " "), cursor.y == p.cell.y, cursor.x <= p.cell.x, caret != nil { return false }
            confident = false
            contradicted = true
            return true
        }
        if pending.isEmpty {
            settle(cursor: cursor, now: now, atOnce: contradicted)
            if caret == nil { superseded.removeAll(keepingCapacity: true) }
        }
    }

    /// With nothing pending, the caret stays until the cursor reaches it.
    private mutating func settle(cursor: (x: UInt16, y: UInt16), now: Date, atOnce: Bool) {
        guard let c = caret, !atOnce, c.x != cursor.x || c.y != cursor.y else {
            caret = nil
            settleUntil = nil
            return
        }
        if settleUntil == nil { settleUntil = now.addingTimeInterval(0.15) }
    }

    /// Drops predictions the server never answered.
    mutating func expire(now: Date = Date()) {
        if let until = settleUntil, now >= until {
            settleUntil = nil
            caret = nil
        }
        let timeout = min(max(srtt * 3, 0.25), 2)
        superseded.removeAll { now.timeIntervalSince($0.at) > timeout }
        guard !pending.isEmpty else {
            if superseded.isEmpty, settleUntil == nil { caret = nil }
            return
        }
        let before = pending.count
        pending.removeAll { now.timeIntervalSince($0.at) > timeout }
        if pending.count < before { confident = false }
        if pending.isEmpty { caret = nil }
    }

    /// Where the next character lands: after pending predictions, else at
    /// the terminal's cursor; nil when there is no safe answer.
    private func nextCaret(in terminal: VTTerminal) -> (x: UInt16, y: UInt16)? {
        guard terminal.viewportIsActive, !terminal.isAlternateScreen || terminal.cursorVisible else { return nil }
        let cursor = terminal.cursor
        if !pending.isEmpty || !superseded.isEmpty {
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
