import AppKit
import Testing
@testable import Koi

/// Composition is local drawing state: commits and cancellation must never
/// accidentally turn an IME's confirmation key into terminal input.
@Suite @MainActor struct CompositionTests {
    @Test func partialCommitsSurviveTheNextMarkedSegmentAndControlKeysStayWithTheIME() {
        #expect(TerminalView.compositionCommits(["確定", "\r"], before: true, after: true) == ["確定"])
        #expect(TerminalView.compositionCommits(["確定"], before: true, after: false) == ["確定"])
        #expect(TerminalView.compositionCommits(["\u{1b}", "\u{7f}"], before: true, after: false) == [])
        #expect(TerminalView.compositionCommits([], before: true, after: false) == [])
        #expect(TerminalView.compositionCommits(["a"], before: false, after: false) == nil)
    }

    @Test func markedRangesAreBoundedInUTF16AndCancellationClearsThem() {
        let view = TerminalView(pane: "composition", at: .local)
        view.setMarkedText("😀日本", selectedRange: NSRange(location: 2, length: 99), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 4))
        #expect(view.selectedRange() == NSRange(location: 2, length: 2))
        var actual = NSRange()
        let text = view.attributedSubstring(forProposedRange: NSRange(location: 2, length: Int.max), actualRange: &actual)
        #expect(text?.string == "日本")
        #expect(actual == NSRange(location: 2, length: 2))
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(view.selectedRange().location == NSNotFound)
    }

    @Test func compositionWrapsAtTheGridAndCandidateGeometryFollowsTheCaret() {
        let view = CompositionView(frame: NSRect(x: 0, y: 0, width: 80, height: 64))
        let text = NSAttributedString(string: "日本語の入力テスト")
        view.update(text, selected: NSRange(location: text.length, length: 0),
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    cell: NSSize(width: 8, height: 16), grid: NSSize(width: 80, height: 64),
                    cursor: NSPoint(x: 7, y: 3), foreground: .white, background: .black)
        #expect(!view.isHidden)
        #expect(view.caretRect.width > 0 && view.caretRect.height > 0)
        #expect(view.caretRect.minY > 0)
        #expect(view.bounds.intersects(view.caretRect))
        #expect(view.hitTest(.zero) == nil)
        let long = NSAttributedString(string: String(repeating: "日本語", count: 20))
        view.update(long, selected: NSRange(location: long.length, length: 0),
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    cell: NSSize(width: 8, height: 16), grid: NSSize(width: 80, height: 32),
                    cursor: NSPoint(x: 7, y: 1), foreground: .white, background: .black)
        #expect(view.caretRect.minY >= 0 && view.caretRect.maxY <= 32)
        view.clear()
        #expect(view.isHidden)
        #expect(view.caretRect == .zero)
    }
}
