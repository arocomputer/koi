import Foundation
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

    /// Learn an echoed space, then put the fixture's prompt cursor back where it began.
    private func echoingPrediction(in terminal: VTTerminal) -> Prediction {
        var prediction = Prediction()
        prediction.typed(" ", in: terminal)
        terminal.write(Array(" ".utf8))
        prediction.reconcile(with: terminal)
        terminal.write(Array("\u{8} \u{8}".utf8))
        return prediction
    }

    /// Program names and held redraw fragments cannot establish echo confidence.
    @Test func unconfirmedInputStaysHiddenUntilACompletedEcho() {
        for program in ["", "codex", "claude"] {
            let terminal = prompt()
            var prediction = Prediction()
            prediction.setProgram(program)
            prediction.typed("a", in: terminal)
            #expect(prediction.overlay.cells.isEmpty && prediction.overlay.caret == nil)
            terminal.write(Array("\u{1b}[?2026ha".utf8))
            prediction.reconcile(with: terminal)
            prediction.typed("b", in: terminal)
            #expect(prediction.overlay.cells.isEmpty)
            terminal.write(Array("\u{1b}[?2026l".utf8))
            prediction.reconcile(with: terminal)
            #expect(prediction.overlay.cells.isEmpty && !prediction.isActive)
        }
    }

    /// Matching pre-existing text is not evidence until the cursor advances.
    @Test func identicalNonblankNeedsEchoEvidence() {
        let t = prompt()
        t.write(Array("a\u{8}".utf8))
        var p = Prediction()
        p.typed("a", in: t)
        t.write(Array("\u{1b}[0m".utf8))
        p.reconcile(with: t)
        p.typed("b", in: t)
        #expect(p.overlay.cells.isEmpty && p.overlay.caret == nil)
        t.write(Array("a".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells == [Prediction.Cell(x: 3, y: 0, text: "b")])
    }

    /// Neither an existing prediction nor input during a hold uses the partial grid.
    @Test func heldRedrawClearsAndSuppressesPredictions() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.typed("a", in: t)
        #expect(!p.overlay.cells.isEmpty)
        t.write(Array("\u{1b}[?2026h\u{1b}[10G".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive && p.overlay.cells.isEmpty && p.overlay.caret == nil)
        p.typed("b", in: t)
        p.backspace(in: t)
        #expect(!p.isActive && p.overlay.cells.isEmpty && p.overlay.caret == nil)
        t.write(Array("\u{1b}[?2026l".utf8))
        p.reconcile(with: t)
        p.typed("c", in: t)
        #expect(p.isActive && p.overlay.cells.isEmpty)
        t.write(Array("c".utf8))
        p.reconcile(with: t)
        p.typed("d", in: t)
        #expect(p.overlay.cells.map(\.text) == ["d"])
    }

    /// Separate intermediate echoes must not displace the final prediction.
    @Test func retypingKeepsTheOverlayThroughIntermediateEchoes() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.typed("a", in: t)
        p.backspace(in: t)
        p.typed("b", in: t)
        let expected = [Prediction.Cell(x: 2, y: 0, text: "b")]
        #expect(p.overlay.cells == expected && p.overlay.caret?.x == 3)
        t.write(Array("a".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells == expected && p.overlay.caret?.x == 3)
        t.write(Array("\u{8} \u{8}".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells == expected && p.overlay.caret?.x == 3)
        t.write(Array("b".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive && p.overlay.caret == nil)
    }

    /// Enter, navigation and a program switch discard earlier echo confidence.
    @Test func unpredictableInputRequiresFreshEchoBeforePrediction() {
        for action in 0..<3 {
            let terminal = prompt()
            var prediction = echoingPrediction(in: terminal)
            switch action {
            case 0: prediction.entered()
            case 1: prediction.other()
            default: prediction.setProgram("codex")
            }
            prediction.typed("a", in: terminal)
            #expect(prediction.overlay.cells.isEmpty && prediction.overlay.caret == nil)
        }
    }

    @Test func typingShowsAtOnceAndClearsWhenEchoed() {
        let t = prompt()
        var p = echoingPrediction(in: t)
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

    @Test func backspaceCoversAnInFlightCharacterUntilItsErase() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.typed("a", in: t)
        p.backspace(in: t)
        #expect(p.overlay.cells == [Prediction.Cell(x: 2, y: 0, text: " ")])
        #expect(p.overlay.caret?.x == 2)
        t.write(Array("a".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells.count == 1)
        t.write(Array("\u{8} ".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells.isEmpty)
        #expect(p.overlay.caret?.x == 2)
        t.write(Array("\u{8}".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)
        #expect(p.overlay.caret == nil)
    }

    @Test func blanksNeedEvidenceBeforeConfirmation() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.typed(" ", in: t)
        t.write(Array("\u{1b}[0m".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells.count == 1, "unrelated output does not confirm a space")
        t.write(Array(" ".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)

        p.backspace(in: t)
        t.write(Array("\u{1b}[0m".utf8))
        p.reconcile(with: t)
        #expect(p.overlay.cells.count == 1, "an unchanged blank does not confirm an erase")
    }

    @Test func unpredictableInputClearsAllPredictions() {
        let t = prompt()
        for enter in [false, true] {
            var p = echoingPrediction(in: t)
            p.typed("a", in: t)
            if enter { p.entered() } else { p.other() }
            #expect(p.overlay.cells.isEmpty)
            #expect(p.overlay.caret == nil)
            #expect(!p.isActive)
        }
        for text in ["paste", "日本"] {
            var p = echoingPrediction(in: t)
            p.typed("a", in: t)
            p.typed(text, in: t)
            #expect(!p.isActive)
            #expect(p.overlay.cells.isEmpty && p.overlay.caret == nil)
        }
    }

    @Test func expiryClearsTheWholePredictionAndCaret() {
        let t = prompt()
        let start = Date(timeIntervalSince1970: 100)
        var p = echoingPrediction(in: t)
        p.typed("a", in: t, now: start)
        p.typed("b", in: t, now: start.addingTimeInterval(0.2))
        p.expire(now: start.addingTimeInterval(0.31))
        #expect(!p.isActive)
        #expect(p.overlay.cells.isEmpty)
        #expect(p.overlay.caret == nil)
        p.backspace(in: t, now: start.addingTimeInterval(0.32))
        #expect(!p.isActive)
    }

    @Test func aCoalescedCancellationExpiresAndResetsTheCaret() {
        let t = prompt()
        let start = Date(timeIntervalSince1970: 100)
        var p = echoingPrediction(in: t)
        p.typed("a", in: t, now: start)
        p.backspace(in: t, now: start)
        t.write(Array("a\u{8} \u{8}".utf8))
        p.reconcile(with: t, now: start.addingTimeInterval(0.1))
        #expect(p.isActive)
        p.expire(now: start.addingTimeInterval(0.31))
        #expect(!p.isActive)
        #expect(p.overlay.caret == nil)
        p.typed("b", in: t, now: start.addingTimeInterval(0.32))
        #expect(p.overlay.cells.isEmpty, "expired confidence must be learned again")
        t.write(Array("b".utf8))
        p.reconcile(with: t, now: start.addingTimeInterval(0.33))
        p.typed("c", in: t, now: start.addingTimeInterval(0.34))
        #expect(p.overlay.cells == [Prediction.Cell(x: 3, y: 0, text: "c")])
    }

    @Test func resetClearsACaretWaitingForTheFinalBackspace() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.typed("a", in: t)
        t.write(Array("a".utf8))
        p.reconcile(with: t)
        p.backspace(in: t)
        t.write(Array("\u{8} ".utf8))
        p.reconcile(with: t)
        #expect(p.isActive)
        p.reset()
        #expect(!p.isActive)
        #expect(p.overlay.caret == nil)
    }

    @Test func typingDuringSplitEraseUsesTheHeldCaret() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.typed("a", in: t)
        t.write(Array("a".utf8))
        p.reconcile(with: t)
        p.backspace(in: t)
        t.write(Array("\u{8} ".utf8))
        p.reconcile(with: t)
        p.typed("b", in: t)
        #expect(p.overlay.cells == [Prediction.Cell(x: 2, y: 0, text: "b")])
        #expect(p.overlay.caret?.x == 3)
        t.write(Array("\u{8}b".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)
    }

    /// An erase echoes as backspace, space, backspace; when the space has
    /// arrived but not the last backspace, the cursor must not jump right
    /// for a frame.
    @Test func theCaretHoldsUntilTheCursorCatchesUp() {
        let t = prompt()
        t.write(Array("ab".utf8))
        var p = echoingPrediction(in: t)
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

    @Test func unverifiedProgramsDoNotPaintGuesses() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.setProgram("vim")
        p.typed("x", in: t)
        #expect(p.overlay.cells.isEmpty, "a new program has not demonstrated echo")
        t.write(Array("?".utf8))
        p.reconcile(with: t)
        #expect(!p.isActive)
        p.typed("x", in: t)
        #expect(p.overlay.cells.isEmpty && p.overlay.caret == nil, "a wrong guess stays hidden until echo matches")
    }

    /// Aliases and unfamiliar programs all learn echo after reconnect.
    @Test(arguments: ["custom-editor", "claude-code", "gemini-cli", "opencode-cli", "opencode-ai", "pi-coding-agent", "aider-chat"])
    func programsLearnEchoAfterReconnect(program: String) {
        let t = prompt()
        var p = Prediction()
        p.setProgram(program)
        p.reset()
        p.typed("a", in: t)
        p.typed("b", in: t)
        #expect(p.overlay.cells.isEmpty && p.overlay.caret == nil)
        t.write(Array("ab".utf8))
        p.reconcile(with: t)
        p.typed("c", in: t)
        #expect(p.overlay.cells.map(\.text) == ["c"])
    }

    /// A coalesced identical replacement must still be covered by a later erase.
    @Test func backspaceHidesAnIdenticalReplacementAfterCoalescedEcho() {
        let t = prompt()
        var p = echoingPrediction(in: t)
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

    /// Delayed fragments of a canceled key cannot displace its replacement.
    @Test(arguments: ["a", "b"], [0, 2])
    func delayedEchoOfACorrectedCharacterDoesNotEraseNewerTyping(replacement: String, echoedFragments: Int) {
        let t = prompt()
        var p = echoingPrediction(in: t)
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

    @Test func nothingIsPredictedWhileScrolledBack() {
        let t = VTTerminal(cols: 40, rows: 3)
        t.write(Array((1...10).map { "line \($0)\r\n" }.joined().utf8))
        t.scroll(rows: -5)
        var p = echoingPrediction(in: t)
        p.typed("a", in: t)
        #expect(!p.isActive)
    }

    /// An inline TUI draws its own caret with the terminal cursor hidden;
    /// typing there is not predicted.
    @Test func hiddenCursorNeverPredicts() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        t.write(Array("\u{1b}[?25l".utf8))
        p.reconcile(with: t)
        p.typed("a", in: t)
        #expect(p.overlay == Prediction.Overlay() && !p.isActive)
    }

    /// Full-screen programs compose their own frame; a character at the cursor
    /// is not their echo.
    @Test func alternateScreenNeverPredicts() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        t.write(Array("\u{1b}[?1049h".utf8))
        p.reconcile(with: t)
        p.typed("a", in: t)
        #expect(p.overlay == Prediction.Overlay() && !p.isActive)
    }

    /// Shell metadata can lag a command that disables echo; it must not
    /// reveal input or a predicted caret after Enter.
    @Test(arguments: [false, true])
    func shellDoesNotPredictHiddenInputAfterEnter(programChanges: Bool) {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.typed("x", in: t)
        p.entered()
        t.write(Array("\r\nPassword: ".utf8))
        if programChanges { p.setProgram("custom-command") }
        p.setProgram("")
        for text in ["a", "b"] {
            p.typed(text, in: t)
            p.reconcile(with: t)
            #expect(p.overlay == Prediction.Overlay())
        }
        p.backspace(in: t)
        p.typed("c", in: t)
        #expect(p.overlay == Prediction.Overlay())
    }

    /// A new shell prompt alone does not restore confidence; a matching
    /// echo does, and the next Enter must invalidate it again.
    @Test func shellPredictionResumesOnlyAfterMatchingEcho() {
        let t = prompt()
        var p = echoingPrediction(in: t)
        p.entered()
        t.write(Array("\r\n$ ".utf8))
        p.reconcile(with: t)
        p.typed("a", in: t)
        p.typed("b", in: t)
        p.reconcile(with: t)
        #expect(p.overlay == Prediction.Overlay())

        t.write(Array("ab".utf8))
        p.reconcile(with: t)
        p.typed("c", in: t)
        #expect(p.overlay.cells.map(\.text) == ["c"])
        #expect(p.overlay.caret?.x == 5)

        p.entered()
        p.typed("d", in: t)
        #expect(p.overlay == Prediction.Overlay())
    }
}
