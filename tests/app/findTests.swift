import AppKit
import Testing
@testable import Koi

extension SessionTests {
    /// Metadata refreshes preserve Find's editor, while pane selection
    /// still returns keyboard ownership to the newly selected terminal.
    @Test @MainActor func findFocusSurvivesWindowPresentationUpdates() async throws {
        let server = try TestServer()
        defer { server.stop() }
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let window = delegate.makeWindow()
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            window.close()
        }
        let workspace = delegate.workspace
        // Keep the synthetic tree authoritative instead of accepting watcher
        // snapshots from the workspace's automatically started connection.
        workspace.detachAll()
        workspace.onShow = { [weak delegate] in delegate?.show($0) }
        var first = Wire.PaneInfo(id: "find-a", pid: 1, title: "", cwd: "/tmp", home: "/tmp",
                                  program: "", shell: "zsh", fullscreen: false, status: .idle)
        let second = Wire.PaneInfo(id: "find-b", pid: 1, title: "", cwd: "/tmp", home: "/tmp",
                                  program: "", shell: "zsh", fullscreen: false, status: .idle)
        let layout = Wire.LayoutNode.split(.init(id: "find-split", direction: .right, children: [
            .init(layout: .pane(first.id), weight: 1), .init(layout: .pane(second.id), weight: 1),
        ]))
        func report() {
            workspace.apply(.init(items: [.tab(.init(id: "find-tab", panes: [first, second], layout: layout))]))
        }
        report()
        let terminal = try #require(workspace.selectedView)
        #expect(window.firstResponder === terminal)
        terminal.performFind(nil)
        let editor = try #require(window.firstResponder as? NSTextView)
        let field = try #require(editor.delegate as? NSTextField)
        #expect(field.isDescendant(of: terminal))
        editor.string = "query"
        field.stringValue = "query"
        terminal.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

        first.program = "vim"
        first.title = "Document"
        first.cwd = "/tmp/document"
        first.status = .working
        report()
        #expect(window.firstResponder === editor, "live status must preserve Find focus")
        try await Task.sleep(for: .milliseconds(350))
        #expect(window.firstResponder === editor, "deferred presentation must preserve Find focus")
        #expect(field.stringValue == "query")

        workspace.focus(second.id)
        #expect(window.firstResponder === workspace.selectedView, "selecting another pane still focuses it")
        workspace.focus(first.id)
        #expect(window.firstResponder === terminal)
    }

    /// Replacing a snapshot with an active search releases the old mirror;
    /// ending the replacement search twice must remain safe during teardown.
    @Test @MainActor func replacingTerminalWithActiveFindReleasesOldMirror() throws {
        let view = TerminalView(pane: "find-replacement", at: .local)
        let source = VTTerminal(cols: 40, rows: 4)
        source.write(Array("needle needle".utf8))
        let snapshot = source.snapshot()
        #expect(view.restoreTerminal(from: snapshot))
        weak var previous: VTTerminal?
        previous = view.terminal
        #expect(view.terminal?.searchStart("needle") == 2)
        #expect(view.terminal?.searchSelect(next: true)?.index == 1)
        #expect(view.restoreTerminal(from: snapshot))
        #expect(previous == nil)
        #expect(view.terminal?.searchStart("needle") == 2)
        view.terminal?.searchEnd()
        view.terminal?.searchEnd()
        #expect(view.terminal?.searchSelect(next: true) == nil)
        #expect(view.terminal?.hasSelection == false)
    }

    /// Dropping the sole terminal owner with a selected search must be safe
    /// without an explicit Find dismissal. Also used for native leak inspection.
    @Test @MainActor func destroyingTerminalWithActiveFind() {
        weak var released: VTTerminal?
        do {
            let terminal = VTTerminal(cols: 40, rows: 4)
            released = terminal
            terminal.write(Array("needle needle".utf8))
            #expect(terminal.searchStart("needle") == 2)
            #expect(terminal.searchSelect(next: true)?.index == 1)
        }
        #expect(released == nil)
    }
}
