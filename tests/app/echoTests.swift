import Testing
@testable import Koi

/// The predictor against a real engine terminal: a shell at its prompt that
/// echoes late.
@Suite struct PredictionTests {
    private func prompt() -> VTTerminal {
        let t = VTTerminal(cols: 40, rows: 5)
        t.write(Array("$ ".utf8))
        return t
    }

    @Test func typingShowsAtOnceAndClearsWhenEchoed() {
        let t = prompt()
        var p = Prediction()
        p.typed("l", in: t)
        p.typed("s", in: t)
        #expect(p.overlay.cells.map(\.text) == ["l", "s"])
        #expect(p.overlay.caret?.x == 4)

        t.write(Array("l".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells.map(\.text) == ["s"], "the echoed letter is the grid's now")
        t.write(Array("s".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)
    }

    @Test func backspaceTakesBackAPredictionOrPredictsAnErase() {
        let t = prompt()
        var p = Prediction()
        p.typed("a", in: t)
        p.backspace(in: t)
        #expect(p.overlay.cells.isEmpty, "an unconfirmed letter is simply taken back")

        t.write(Array("a".utf8))
        p.typed("a", in: t)
        t.write(Array("a".utf8))
        p.reconcile(with: t)
        p.backspace(in: t)
        #expect(p.overlay.cells == [Prediction.Cell(x: 3, y: 0, text: " ")], "a confirmed letter is erased on screen")
        #expect(p.overlay.caret?.x == 3)
    }

    /// An erase echoes as backspace, space, backspace; when the space has
    /// arrived but not the last backspace, the cursor must not jump right
    /// for a frame.
    @Test func theCaretHoldsUntilTheCursorCatchesUp() {
        let t = prompt()
        t.write(Array("ab".utf8))
        var p = Prediction()
        p.typed("c", in: t)
        t.write(Array("c".utf8))
        p.reconcile(with: t)
        p.backspace(in: t)
        #expect(p.overlay.caret?.x == 4)
        t.write(Array("\u{8} ".utf8)) // the cursor is back on the space, one cell right of the caret
        p.reconcile(with: t)
        #expect(p.overlay.caret?.x == 4, "held while the cursor is still right of it")
        t.write(Array("\u{8}".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.caret == nil, "settled once the cursor is there")
    }

    @Test func aContradictedPredictionGoesAndStopsFurtherOnes() {
        let t = prompt()
        var p = Prediction()
        p.setProgram("vim")
        p.typed("x", in: t)
        #expect(p.overlay.cells.count == 1, "vim at a text position is given the benefit of the doubt once")
        t.write(Array("?".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)
        p.typed("x", in: t)
        #expect(!p.isActive, "after a wrong guess nothing is shown until an echo matches")
    }

    @Test func nothingIsPredictedWhileScrolledBack() {
        let t = VTTerminal(cols: 40, rows: 3)
        t.write(Array((1...10).map { "line \($0)\r\n" }.joined().utf8))
        t.scroll(rows: -5)
        var p = Prediction()
        p.typed("a", in: t)
        #expect(!p.isActive)
    }
}
