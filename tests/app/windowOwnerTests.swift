import AppKit
import Testing
@testable import Koi

extension SessionTests {
    /// A second client owns its selection and survives the first client closing.
    /// All windows stay offscreen and all shells belong to this private server.
    @Test @MainActor func closingOneWindowPreservesAnotherWindowsSelectionAndServer() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let first = AppDelegate()
        first.launchWindow(present: false)
        let second = first.newWindowOwner(present: false)
        defer {
            first.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            first.window.close()
            second.window.close()
        }
        try await waitForWindowState { !first.workspace.state.tabs.isEmpty && !second.workspace.state.tabs.isEmpty }
        let a = try #require(first.workspace.state.tabs.first?.id)
        let made = try await second.workspace.perform(.init(op: .newTab))
        let b = try #require(made.tab)
        try await waitForWindowState { first.workspace.tab(b) != nil && second.workspace.tab(b) != nil }
        first.workspace.select(a)
        second.workspace.select(b)
        #expect(first.workspace.selectedTab == a)
        #expect(second.workspace.selectedTab == b)
        weak var closedTerminal = first.workspace.selectedView
        #expect(closedTerminal != nil)
        first.window.close()
        try await waitForWindowState { closedTerminal == nil }
        #expect(second.windowOwners.count == 1)
        #expect(second.workspace.selectedTab == b)
        let pane = try #require(second.workspace.tab(a)?.tab.panes.first?.id)
        #expect(first.focusActivity(endpoint: .local, tab: a, pane: pane, present: false))
        #expect(second.workspace.selectedTab == a)
        #expect(!first.focusActivity(endpoint: .local, tab: b, pane: "missing", present: false))
        #expect(second.workspace.selectedTab == a)
        let another = try await second.workspace.perform(.init(op: .newTab))
        #expect(another.error == nil && another.tab != nil)
        #expect(!second.window.isVisible)
    }
}

/// Await real control delivery without activating a fixture window.
@MainActor private func waitForWindowState(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("private window state did not arrive")
    throw WorkspaceCommandError("Timed out waiting for private window state")
}
