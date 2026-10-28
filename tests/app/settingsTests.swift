import AppKit
import SwiftUI
import Testing
@testable import Koi

/// Search reaches controls in another category and combines words across metadata.
@Test func settingsSearchFindsControlsAcrossCategories() throws {
    let font = try #require(SettingsItem.all.first { $0.id == "font-size" })
    let activity = try #require(SettingsItem.all.first { $0.id == "notify-blocked" })
    #expect(font.matches("TERMINAL font 72"))
    #expect(font.matches("font-size"))
    #expect(!font.matches("font notification"))
    #expect(activity.matches("activity waiting attention"))
    #expect(SettingsItem.all.allSatisfy { $0.matches(" \n ") })
}

/// Shortcut search can combine its group, action ID and the recorded trigger.
@Test func settingsShortcutSearchMatchesActionAndTrigger() {
    let action = Action.focusSplitLeft
    let bind = Keybind("j", [.command, .option])
    let fields = ["Shortcuts", SettingsSearch.group(action), action.title, action.rawValue, bind.symbols, bind.configString]
    #expect(SettingsSearch.matches("panes cmd+alt+j", in: fields))
    #expect(SettingsSearch.matches("focus_split_left ⌥⌘J", in: fields))
    #expect(!SettingsSearch.matches("cmd+alt+k", in: fields))
}

/// Buttons and dragging clamp at either end, including rubber banding and resize.
@Test func settingsCategoryScrollingStopsAtEnds() {
    var bounds = SettingsScrollBounds(offset: 0, width: 300, contentWidth: 800)
    #expect(!bounds.canGoLeft)
    #expect(bounds.canGoRight)
    #expect(bounds.page(-1) == 0)
    #expect(bounds.page(1) > 0)
    #expect(bounds.clamped(-100) == 0)
    #expect(bounds.clamped(900) == 500)
    bounds.offset = 500
    #expect(bounds.canGoLeft)
    #expect(!bounds.canGoRight)
    #expect(bounds.page(1) == 500)
    #expect(bounds.page(-1) < 500)
    bounds.offset = -30
    #expect(!bounds.canGoLeft)
    bounds.width = 1000
    #expect(!bounds.canGoLeft)
    #expect(!bounds.canGoRight)
    #expect(bounds.page(1) == 0)
    bounds.offset = 500
    #expect(!bounds.canGoLeft)
    #expect(!bounds.canGoRight)
}

@MainActor extension SessionTests {
    /// Losing focus and Command-W dismiss only the compact Settings window.
    @Test func settingsWindowClosesOnBlurAndCommandW() async throws {
        _ = NSApplication.shared
        let window = SettingsWindow()
        defer { window.close() }
        var closes = 0
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { closes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        window.resignKey()
        try await Task.sleep(for: .milliseconds(10))
        #expect(closes == 1)
        let shortcutWindow = SettingsWindow()
        defer { shortcutWindow.close() }
        let shortcutToken = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: shortcutWindow, queue: .main) { _ in
            MainActor.assumeIsolated { closes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(shortcutToken) }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: shortcutWindow.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(shortcutWindow.performKeyEquivalent(with: event))
        #expect(closes == 2)
    }

    /// Window menu actions and the fullscreen shortcut cannot enlarge Settings.
    @Test func settingsWindowKeepsItsCompactFrame() throws {
        _ = NSApplication.shared
        let window = SettingsWindow()
        defer { window.close() }
        let frame = window.frame
        #expect(!window.styleMask.contains(.resizable))
        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        window.zoom(nil)
        window.performZoom(nil)
        window.toggleFullScreen(nil)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(window.performKeyEquivalent(with: event))
        #expect(window.frame == frame)
    }

    /// Optional view previews check normal and narrow layouts independently
    /// of the fixed-size window, without activation or user configuration changes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOI_VISUALS"] != nil))
    @MainActor func settingsWindowPreviews() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KOI_VISUALS"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = Config.current
        defer { Config.current = previous }
        Config.current = Config()
        let view = SettingsView(apply: { _, _ in }, rebind: { _, _ in }, reset: { _ in }, resetKeybind: { _ in },
            openConfigFile: {}, machines: { AnyView(EmptyView()) }, version: "Development",
            openLogs: {}, copyDiagnostics: {}, checkForUpdates: {}, installCLI: {})
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.current.backgroundColor)
        window.contentView = host
        defer { window.close() }
        for width in [700, 520] {
            window.setContentSize(NSSize(width: width, height: 560))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("settings-dark-\(width).png"))
        }
    }
}
