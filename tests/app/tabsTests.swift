import AppKit
import SwiftUI
import Testing
@testable import Koi

extension SessionTests {
    /// Real hosted geometry feeds all three placements. Dragging keeps rows
    /// intact, and release commits one insertion to a private server.
    @Test @MainActor func tabStripsCommitUsingTheirRenderedTargets() async throws {
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        let control = try #require(TestControl())
        let a = try #require(control.run(.init(op: .newTab)).tab)
        let b = try #require(control.run(.init(op: .newTab, tab: a)).tab)
        let c = try #require(control.run(.init(op: .newTab, tab: b)).tab)
        _ = control.run(.init(op: .group, tab: c, target: b, name: "Work"))
        let machines = Machines()
        machines.start()
        let workspace = machines.workspace
        defer { workspace.detachAll() }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        for placement in [Config.Tabs.side, .top, .right] {
            let horizontal = placement == .top
            let label = placement == .side ? "left" : horizontal ? "top" : "right"
            if workspace.tab(a)?.group != nil {
                // Restore the source to the top level rather than the group.
                workspace.commitTabDrag(a, placement: .insert(b, after: false, outside: true)) { _ in }
            }
            for _ in 0..<200 {
                if workspace.state.tabs.map(\.id) == [a, b, c], workspace.tab(a)?.group == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(workspace.state.tabs.map(\.id) == [a, b, c])
            Config.current.tabs = placement
            let drag = TabDrag(horizontal: horizontal)
            let view: AnyView = horizontal ? AnyView(HorizontalBar(machines: machines, drag: drag))
                                           : AnyView(SidebarView(machines: machines, drag: drag))
            let size = horizontal ? NSSize(width: 1000, height: 52) : NSSize(width: 248, height: 500)
            let host = NSHostingView(rootView: AnyView(view.preferredColorScheme(.dark)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.setFrameSize(size)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if drag.frame(for: .tab(c)) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let group = try #require(workspace.tab(b)?.group?.id)
            workspace.toggleCollapsed(group)
            for _ in 0..<100 {
                if drag.frame(for: .tab(b)) == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(drag.frame(for: .tab(b)) == nil && drag.frame(for: .tab(c)) == nil)
            workspace.toggleCollapsed(group)
            for _ in 0..<100 {
                if drag.frame(for: .tab(c)) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let source = try #require(drag.frame(for: .tab(a)))
            let target = try #require(drag.frame(for: .tab(b)))
            #expect(source.width > 0 && target.width > 0)
            writeStripPreview(host, name: label + "-tabs")
            drag.begin(at: CGPoint(x: source.minX + 12, y: source.midY), state: workspace.state, renaming: nil)
            drag.update(to: horizontal ? CGPoint(x: target.maxX - 3, y: target.midY)
                                       : CGPoint(x: target.midX, y: target.maxY - 3))
            #expect(drag.active)
            #expect(drag.placement == .insert(b, after: true, outside: false))
            #expect(workspace.state.tabs.map(\.id) == [a, b, c])
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            writeStripPreview(host, name: label + "-drag")
            #expect(drag.frame(for: .tab(a)) == source, "the source row stays in its real slot during dragging")
            let (id, insertion) = try #require(drag.finish())
            #expect(!drag.active && drag.source == nil)
            workspace.commitTabDrag(id, placement: insertion) { success in if !success { drag.cancel() } }
            for _ in 0..<200 {
                if workspace.state.tabs.map(\.id) == [b, a, c] { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(workspace.state.tabs.map(\.id) == [b, a, c])
            #expect(workspace.tab(a)?.group?.id == workspace.tab(b)?.group?.id)
            drag.cancel()
        }
    }

    /// The compact picker starts beside the real native controls, including
    /// after resizing. This uses the production window without showing it.
    @Test @MainActor func horizontalPickerDoesNotOverlapTrafficLights() async throws {
        _ = NSApplication.shared
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        let control = try #require(TestControl())
        for _ in 0..<3 { _ = control.run(.init(op: .newTab)) }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        Config.current.tabs = .top
        let delegate = AppDelegate()
        let window = delegate.makeWindow()
        window.isReleasedWhenClosed = false
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); window.close() }
        let root = try #require(window.contentView)
        let bar = try #require(root.subviews.compactMap { $0 as? NSHostingView<HorizontalBar> }.first)
        for width in [1000.0, 700, 480] {
            window.setContentSize(NSSize(width: width, height: 500))
            root.superview?.layoutSubtreeIfNeeded()
            delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            let trailing = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { type in
                let button = try #require(window.standardWindowButton(type))
                return root.convert(button.bounds, from: button).maxX
            }.max() ?? 0
            let gap = bar.frame.minX - trailing
            #expect(gap >= 0, "the machine picker must not overlap native controls")
        }
        window.setContentSize(NSSize(width: 1000, height: 500))
        root.superview?.layoutSubtreeIfNeeded()
        delegate.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        if ProcessInfo.processInfo.environment["KOI_VISUALS"] != nil {
            try await Task.sleep(for: .milliseconds(300))
            writeStripPreview(root.superview ?? root, name: "top-window")
        }
    }

    /// Closing the first horizontal tab keeps its successor in that same slot,
    /// and selection waits for the authoritative removal rather than chasing
    /// an obsolete slot. No screen capture or application activation is involved.
    @Test @MainActor func closingFirstHorizontalTabKeepsItsSuccessorInPlace() async throws {
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        let control = try #require(TestControl())
        let a = try #require(control.run(.init(op: .newTab)).tab)
        let b = try #require(control.run(.init(op: .newTab, tab: a)).tab)
        _ = control.run(.init(op: .newTab, tab: b))
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.tabs = .top
        Config.current.motion = .natural
        let machines = Machines()
        machines.start()
        let workspace = machines.workspace
        defer { workspace.detachAll() }
        for _ in 0..<200 {
            if workspace.state.tabs.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.select(a)
        let drag = TabDrag(horizontal: true)
        let host = NSHostingView(rootView: HorizontalBar(machines: machines, drag: drag)
            .preferredColorScheme(.dark).background(Color(red: 0.08, green: 0.08, blue: 0.1)))
        let size = NSSize(width: 1000, height: 52)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.setFrameSize(size)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if drag.frame(for: .tab(a)) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(drag.frame(for: .tab(a)))
        workspace.closeTab(a)
        #expect(workspace.selectedTab == a, "do not animate toward the successor's obsolete slot")
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            if workspace.selectedTab == b { break }
        }
        #expect(workspace.selectedTab == b)
        let successor = try #require(drag.frame(for: .tab(b)))
        #expect(abs(successor.minX - first.minX) < 1)
        writeStripPreview(host, name: "top-first-tab-closed")
    }

    /// Native click counts select immediately without placing a double-click
    /// recognizer around close controls. Dragging and control clicks stay separate.
    @Test @MainActor func tabClicksSelectImmediatelyAndDoubleClicksRename() async throws {
        _ = NSApplication.shared
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        let control = try #require(TestControl())
        let a = try #require(control.run(.init(op: .newTab)).tab)
        let b = try #require(control.run(.init(op: .newTab)).tab)
        let machines = Machines()
        machines.start()
        let workspace = machines.workspace
        defer { workspace.detachAll() }
        let saved = Config.current.tabs
        defer { Config.current.tabs = saved }
        for placement in [Config.Tabs.side, .top, .right] {
            Config.current.tabs = placement
            let horizontal = placement == .top
            let drag = TabDrag(horizontal: horizontal)
            let view: AnyView = horizontal ? AnyView(HorizontalBar(machines: machines, drag: drag))
                                           : AnyView(SidebarView(machines: machines, drag: drag))
            let size = horizontal ? NSSize(width: 800, height: 52) : NSSize(width: 248, height: 400)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.setFrameSize(size)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if drag.frame(for: .tab(b)) != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let anchor = try #require(clickAnchor(in: host))
            let first = try #require(drag.frame(for: .tab(a)))
            let second = try #require(drag.frame(for: .tab(b)))
            workspace.select(a)
            let point = CGPoint(x: second.minX + 12, y: second.midY)
            try stripMouse(.leftMouseDown, point: point, clicks: 1, anchor: anchor, window: window)
            #expect(workspace.selectedTab == b, "selection happens on the press, without awaiting release or a second click")
            try stripMouse(.leftMouseUp, point: point, clicks: 1, anchor: anchor, window: window)
            #expect(workspace.selectedTab == b)
            let close = CGPoint(x: first.maxX - 12, y: first.midY)
            try stripMouse(.leftMouseDown, point: close, clicks: 1, anchor: anchor, window: window)
            try stripMouse(.leftMouseUp, point: close, clicks: 1, anchor: anchor, window: window)
            #expect(workspace.selectedTab == b && workspace.renamingTab == nil, "the strip must leave close-button clicks alone")
            let start = CGPoint(x: first.minX + 12, y: first.midY)
            let end = CGPoint(x: start.x + 12, y: start.y)
            try stripMouse(.leftMouseDown, point: start, clicks: 1, anchor: anchor, window: window)
            try stripMouse(.leftMouseDragged, point: end, clicks: 1, anchor: anchor, window: window)
            try stripMouse(.leftMouseUp, point: end, clicks: 1, anchor: anchor, window: window)
            #expect(workspace.selectedTab == a, "pressing a tab selects it even when the press becomes a drag")
            workspace.select(b)
            try stripMouse(.leftMouseDown, point: point, clicks: 2, anchor: anchor, window: window)
            try stripMouse(.leftMouseUp, point: point, clicks: 2, anchor: anchor, window: window)
            #expect(workspace.renamingTab == nil, "a click in another control is not the first click of a rename")
            try stripMouse(.leftMouseDown, point: point, clicks: 1, anchor: anchor, window: window)
            try stripMouse(.leftMouseUp, point: point, clicks: 1, anchor: anchor, window: window)
            try stripMouse(.leftMouseDown, point: point, clicks: 2, anchor: anchor, window: window)
            try stripMouse(.leftMouseUp, point: point, clicks: 2, anchor: anchor, window: window)
            #expect(workspace.renamingTab == b)
            workspace.renamingTab = nil
        }
    }

    /// Find the real strip input anchor through native scroll/hosting wrappers.
    @MainActor private func clickAnchor(in view: NSView) -> TabStripWindow.Anchor? {
        if let anchor = view as? TabStripWindow.Anchor { return anchor }
        return view.subviews.compactMap { clickAnchor(in: $0) }.first
    }

    /// Deliver fixture-only pointer events to the app-local monitor, never the screen.
    @MainActor private func stripMouse(_ type: NSEvent.EventType, point: CGPoint, clicks: Int,
                                      anchor: NSView, window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        NSApp.sendEvent(event)
    }

    /// Optional development images contain only the private fixture's tab
    /// chrome. They neither capture the screen nor inspect existing shells.
    @MainActor private func writeStripPreview(_ view: NSView, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["KOI_VISUALS"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + ".png"))
    }


}
