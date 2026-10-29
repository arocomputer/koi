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

    @Test func backspaceTakesBackAnUnconfirmedPrediction() {
        let t = prompt()
        var p = Prediction()
        p.typed("a", in: t)
        p.backspace(in: t)
        #expect(p.overlay.cells.isEmpty, "an unconfirmed letter is simply taken back")
        // The server must echo both input events before the cancellation is
        // settled. A bare 'a' still has its Backspace response in flight.
        t.write(Array("a\u{8} \u{8}".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)
    }

    @Test func backspacePredictsAnEraseOfConfirmedTyping() {
        let t = prompt()
        t.write(Array("a".utf8))
        var p = Prediction()
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

    /// Cursor-moving input and IME commits cannot leave old guesses painted
    /// over a TUI while the next remote reply is in flight.
    @Test func unpredictableInputDropsOutstandingPredictions() {
        let t = prompt()
        for action in [0, 1, 2] {
            var p = Prediction()
            p.typed("a", in: t)
            p.typed("b", in: t)
            #expect(p.overlay.cells.count == 2)
            switch action {
            case 0: p.other()
            case 1: p.entered()
            default: p.typed("日本", in: t)
            }
            #expect(p.overlay.cells.isEmpty)
            #expect(p.overlay.caret == nil)
            #expect(!p.isActive)
        }
    }

    @Test func anUnfamiliarProgramCanRecoverPredictionAfterReconnect() {
        let t = prompt()
        var p = Prediction()
        p.setProgram("custom-editor")
        p.reset()
        p.typed("a", in: t)
        p.typed("b", in: t)
        #expect(p.overlay.cells.isEmpty)
        t.write(Array("ab".utf8))
        p.reconcile(with: t)
        p.typed("c", in: t)
        #expect(p.overlay.cells.map(\.text) == ["c"])
    }

    @Test(arguments: ["claude-code", "gemini-cli", "opencode-cli", "opencode-ai", "pi-coding-agent", "aider-chat"])
    func recognizedAgentPackagesRetainTheirTypingPolicy(program: String) {
        let terminal = prompt()
        var prediction = Prediction()
        prediction.setProgram(program)
        prediction.reset()
        prediction.typed("a", in: terminal)
        #expect(prediction.overlay.cells.map(\.text) == ["a"])
    }

    /// A matching glyph can belong to an earlier canceled key; retain the
    /// conservative overlay, but another Backspace must hide real text too.
    @Test func backspaceHidesAnIdenticalReplacementAfterCoalescedEcho() {
        let t = prompt()
        var p = Prediction()
        p.typed("a", in: t)
        p.backspace(in: t)
        p.typed("a", in: t)
        t.write(Array("a\u{8} \u{8}a".utf8))
        p.reconcile(with: t)
        p.backspace(in: t)
        #expect(p.overlay.cells == [Prediction.Cell(x: 2, y: 0, text: " ")])
        for fragment in ["\u{8}", " ", "\u{8}"] {
            t.write(Array(fragment.utf8))
            p.reconcile(with: t)
        }
        #expect(!p.isActive)
    }

    @Test(arguments: ["a", "b"], [0, 2])
    func delayedEchoOfACorrectedCharacterDoesNotEraseNewerTyping(replacement: String, echoedFragments: Int) {
        let t = prompt()
        var p = Prediction()
        p.typed("a", in: t)
        p.backspace(in: t)
        let fragments = ["a", "\u{8}", " ", "\u{8}"]
        for fragment in fragments.prefix(echoedFragments) {
            t.write(Array(fragment.utf8))
            p.reconcile(with: t)
        }
        p.typed(replacement, in: t)
        for fragment in fragments.dropFirst(echoedFragments) {
            t.write(Array(fragment.utf8))
            p.reconcile(with: t)
            #expect(p.overlay.cells.map(\.text) == [replacement])
        }
        t.write(Array(replacement.utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)
    }
}
