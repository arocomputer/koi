import AppKit
import Testing
@testable import Koi

/// Application-owned mouse selections arrive as OSC 52, independently of
/// Koi's own selection. Never read or write the user's real pasteboard here.
@Suite @MainActor struct ClipboardTests {
    @Test func applicationCopySurvivesEveryOutputSplit() {
        let text = "OpenCode selection 日本語 👋\nsecond line"
        let bytes = Array(("\u{1b}]52;c;" + Data(text.utf8).base64EncodedString() + "\u{1b}\\").utf8)
        let board = NSPasteboard(name: .init("koi.tests.osc52.\(UUID())"))
        defer { board.releaseGlobally() }
        for split in 0...bytes.count {
            let terminal = VTTerminal(cols: 40, rows: 4)
            var copies = 0
            terminal.onClipboardWrite = { value in
                copies += 1
                board.clearContents()
                return board.setString(value, forType: .string)
            }
            terminal.write(Array(bytes[..<split]))
            terminal.write(Array(bytes[split...]))
            #expect(copies == 1)
            #expect(board.string(forType: .string) == text)
            #expect(!terminal.hasSelection, "the application's selection need not be a terminal selection")
        }
    }

    @Test func clipboardReadsAndInvalidWritesDoNotChangeContents() {
        let terminal = VTTerminal(cols: 40, rows: 4)
        var copied: [String] = []
        terminal.onClipboardWrite = { copied.append($0); return true }
        terminal.write(Array("\u{1b}]52;c;?\u{7}\u{1b}]52;c;%%%\u{7}\u{1b}]52;c;/w==\u{7}".utf8))
        #expect(copied.isEmpty)
        terminal.write(Array("\u{1b}]52;c;b2s=\u{7}".utf8))
        #expect(copied == ["ok"])
    }

    @Test func restoringHistoryDoesNotRepeatAClipboardWrite() throws {
        let source = VTTerminal(cols: 40, rows: 4)
        source.write(Array("\u{1b}]52;c;b2xk\u{7}".utf8))
        let restored = try #require(VTTerminal(snapshot: source.snapshot()))
        var copied: [String] = []
        restored.onClipboardWrite = { copied.append($0); return true }
        restored.write(Array("more output".utf8))
        #expect(copied.isEmpty)
        restored.write(Array("\u{1b}]52;c;bmV3\u{7}".utf8))
        #expect(copied == ["new"])
    }

    @Test func clearAndPrimarySelectionsHaveDistinctDestinations() {
        let terminal = VTTerminal(cols: 40, rows: 4)
        var copied: [String] = []
        terminal.onClipboardWrite = { copied.append($0); return true }
        terminal.write(Array("\u{1b}]52;p;cHJpbWFyeQ==\u{7}".utf8))
        #expect(copied.isEmpty)
        terminal.write(Array("\u{1b}]52;c;\u{7}".utf8))
        #expect(copied == [""])
    }

    @Test func acknowledgedClipboardProtocolsCannotWriteAfterTheServerRejectsThem() {
        let transaction = "\u{1b}]5522;type=write:id=c1\u{1b}\\"
            + "\u{1b}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\u{1b}\\"
            + "\u{1b}]5522;type=wdata\u{1b}\\"
        let bytes = Array(transaction.utf8)
        for split in 0...bytes.count {
            let terminal = VTTerminal(cols: 40, rows: 4)
            var copied: [String] = []
            terminal.onClipboardWrite = { copied.append($0); return true }
            terminal.write(Array(bytes[..<split]))
            terminal.write(Array(bytes[split...]))
            #expect(copied.isEmpty)
            terminal.write(Array("\u{1b}]52;c;b2s=\u{7}".utf8))
            #expect(copied == ["ok"])
        }
    }

    @Test func anUnfinishedOSC52RestoresItsClipboardDestination() throws {
        let bytes = Array("\u{1b}]52;c;bmV3\u{7}".utf8)
        for split in 0..<bytes.count {
            let source = VTTerminal(cols: 40, rows: 4)
            source.write(Array(bytes[..<split]))
            let terminal = try #require(VTTerminal(snapshot: source.snapshot()))
            var copied: [String] = []
            terminal.onClipboardWrite = { copied.append($0); return true }
            terminal.write(Array(bytes[split...]))
            #expect(copied == ["new"])
        }
    }
}

/// Models focus transitions without activating a window on the user's desktop.
@MainActor private final class ClipboardWindow: NSWindow {
    var fixtureKey = false
    override var isKeyWindow: Bool { fixtureKey }
}

@MainActor extension SessionTests {
    @Test func applicationClipboardWritesFollowKeyboardFocus() throws {
        _ = NSApplication.shared
        let window = ClipboardWindow(contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 200),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let root = NSView()
        let view = TerminalView(pane: "clipboard-focus", at: .local)
        let other = NSTextField()
        root.addSubview(view)
        root.addSubview(other)
        window.contentView = root
        var writes: [String] = []
        view.clipboardWriter = { writes.append($0); return true }
        #expect(view.restoreTerminal(from: VTTerminal(cols: 10, rows: 2).snapshot()))
        let terminal = try #require(view.terminal)
        let request = Array("\u{1b}]52;c;b2s=\u{7}".utf8)

        #expect(window.makeFirstResponder(view))
        terminal.write(request)
        #expect(writes.isEmpty)
        window.fixtureKey = true
        terminal.write(request)
        #expect(writes == ["ok"])
        #expect(window.makeFirstResponder(other))
        terminal.write(request)
        #expect(writes == ["ok"])
    }
}
