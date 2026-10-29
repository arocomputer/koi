import AppKit
import SwiftUI
import Testing
@testable import Koi

/// Search must find the right work using metadata as well as visible names.
@Suite @MainActor struct PaletteSearchTests {
    @Test func programAndWaitingMustMatchTheSamePane() {
        let waiting = pane("waiting", program: "codex", status: .blocked)
        let working = pane("working", program: "codex", status: .working)
        let other = pane("other", program: "claude", status: .blocked)
        let misleading = pane("misleading", program: "codex", status: .working, title: "Fix waiting queue")
        let results = PaletteSearch.results([working, other, misleading, waiting], query: "CoDeX waiting", recent: [])
        #expect(results.map(\.id) == [waiting.id])
    }

    @Test func directoryGroupMachineAndCustomNameStaySearchable() {
        let info = Wire.PaneInfo(id: "p", pid: 1, title: "Résumé checkout", cwd: "/work/payments",
                                home: "/work", program: "codex", shell: "zsh", fullscreen: false, status: .done)
        let item = PaletteSearch.paneItem(info, tabName: "Release review", group: "Finance", endpoint: .ssh("buildbox"),
                                         isSplit: true, navigate: {})
        for query in ["finance buildbox payments", "release review", "resume", "finished codex", "~/payments"] {
            #expect(PaletteSearch.results([item], query: query, recent: []).count == 1, "query: \(query)")
        }
    }

    @Test func exactProgramMatchesBeatAbbreviationsAndPreserveThePaneTarget() {
        var target = ""
        let exact = pane("exact", program: "codex", status: .working, navigate: { target = "exact" })
        let abbreviation = item("abbreviation", title: "Configure index")
        let results = PaletteSearch.results([abbreviation, exact], query: "codex", recent: [])
        #expect(results.first?.id == exact.id)
        if case .perform(let action) = results.first?.operation { action() }
        #expect(target == "exact")
        #expect(PaletteSearch.results([exact], query: "codx", recent: []).count == 1)
    }

    @Test func recentsIgnoreClosedTargetsAndKeepDestructiveCommandsOutOfTheDefaultTop() {
        var close = item("close", title: "Close Tab")
        close.destructive = true
        let new = item("new", title: "New Tab")
        let work = pane("work", program: "codex", status: .working)
        let results = PaletteSearch.results([close, work, new], query: "", recent: ["gone", close.id, new.id])
        #expect(results.map(\.id) == [new.id, work.id, close.id])
    }

    /// Home lists commands directly by category, closing actions last, with the
    /// work browser beside them and no separate "all commands" step. Disabled
    /// commands leave the browse view but stay reachable through search.
    @Test func homeGroupsCommandsByCategoryWithClosingLast() {
        var settings = item("settings", title: "Settings")
        settings.category = .settings
        var close = item("close_tab", title: "Close Tab")
        close.destructive = true
        var disabled = item("zoom", title: "Zoom Pane")
        disabled.enabled = false
        let all = [settings, item("rename_tab", title: "Rename Tab"), item("new_tab", title: "New Tab"), close, disabled,
                   pane("work", program: "codex", status: .working), pane("other", program: "zsh", status: .idle)]
        let home = PalettePresentation.home(items: { all })
        let rows = home.flatMap(\.items)
        #expect(home.map(\.title) == ["Tabs", "Settings", "Close Actions"])
        #expect(Set(rows.map(\.id)) == Set(["rename_tab", "new_tab", "settings", "close_tab", "browse_work"]))
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(home.last?.items.map(\.id) == ["close_tab"])
        #expect(PaletteSearch.results(all, query: "zoom", recent: []).map(\.id) == ["zoom"])
    }

    @Test func browsingOpenWorkReadsTheLiveCatalog() {
        let catalog = PaletteTestCatalog()
        let home = PalettePresentation.home(items: { catalog.items })
        let browse = home.flatMap(\.items).first { $0.id == "browse_work" }!
        guard case .choices(let make) = browse.operation else { Issue.record("Expected work browser"); return }
        let choices = make()
        let work = pane("arrived", program: "codex", status: .blocked)
        catalog.items = [work, item("find", title: "Find")]
        #expect(choices.items().map(\.id) == [work.id])
        catalog.items = []
        #expect(choices.items().isEmpty)
    }

    private func item(_ id: String, title: String) -> PaletteItem {
        .init(id: id, title: title, detail: "Command", symbol: "command", operation: .perform {})
    }

    private func pane(_ id: String, program: String, status: Wire.Status, title: String = "Review checkout",
                      navigate: @escaping @MainActor () -> Void = {}) -> PaletteItem {
        let info = Wire.PaneInfo(id: id, pid: 1, title: title, cwd: "/work/koi", home: "/work",
                                program: program, shell: "zsh", fullscreen: false, status: status)
        return PaletteSearch.paneItem(info, tabName: "Review", group: "", endpoint: .local,
                                      isSplit: true, navigate: navigate)
    }
}

/// A live catalog reference mirrors the main-actor workspace's changing items.
@MainActor private final class PaletteTestCatalog {
    var items: [PaletteItem] = []
}

/// These join the serialized popup suite so app-local keyboard events cannot
/// interfere with the existing popup lifecycle tests.
@MainActor extension SessionTests {
    @Test @MainActor func paletteArrowsSkipDisabledResultsAndRestoreFocusBeforeExecution() async throws {
        let fixture = PaletteFixture()
        defer { fixture.close() }
        var ranWithFocus = false
        let items: [PaletteItem] = [
            .init(id: "first", title: "First", detail: "Action", symbol: "command", operation: .perform {}),
            .init(id: "disabled", title: "Disabled", detail: "Action", symbol: "command", enabled: false, operation: .perform {}),
            .init(id: "third", title: "Third", detail: "Action", symbol: "command", operation: .perform {
                ranWithFocus = fixture.window.firstResponder === fixture.root && !fixture.presenter.isPresented
            }),
        ]
        fixture.show(items, query: "action")
        try await fixture.waitForInput()
        fixture.key(125, "\u{f701}")
        fixture.key(126, "\u{f700}")
        fixture.key(126, "\u{f700}")
        fixture.key(36, "\r")
        #expect(ranWithFocus)
    }

    @Test @MainActor func palettePromptSubmitsItsPrefilledValueAfterDismissal() async throws {
        let fixture = PaletteFixture()
        defer { fixture.close() }
        var submitted = ""
        let rename = PaletteItem(id: "rename", title: "Rename Tab", detail: "", symbol: "pencil", operation: .prompt {
            PalettePrompt(title: "Rename Tab", placeholder: "Tab name", initial: "New name", submit: {
                if !fixture.presenter.isPresented && fixture.window.firstResponder === fixture.root { submitted = $0 }
            })
        })
        fixture.show([rename], query: "Rename")
        try await fixture.waitForInput()
        fixture.key(36, "\r")
        try await fixture.waitForInput()
        fixture.key(36, "\r")
        #expect(submitted == "New name")
    }

    @Test @MainActor func paletteEscapeDiscardsAnUnsubmittedPrompt() async throws {
        let fixture = PaletteFixture()
        defer { fixture.close() }
        var submitted = false
        fixture.show([.init(id: "rename", title: "Rename", detail: "", symbol: "pencil", operation: .prompt {
            PalettePrompt(title: "Rename", placeholder: "Name", submit: { _ in submitted = true })
        })], query: "Rename")
        try await fixture.waitForInput()
        fixture.key(36, "\r")
        try await fixture.waitForInput()
        fixture.key(36, "\r")
        #expect(fixture.presenter.isPresented, "empty values remain in the prompt")
        fixture.key(53, "\u{1b}", application: true)
        #expect(!submitted)
        #expect(!fixture.presenter.isPresented)
        #expect(fixture.window.firstResponder === fixture.root)
    }

    @Test @MainActor func typingInThePaletteFiltersBeforeReturnExecutes() async throws {
        let fixture = PaletteFixture()
        defer { fixture.close() }
        var chosen = ""
        fixture.show([
            .init(id: "alpha", title: "Alpha", detail: "", symbol: "command", operation: .perform { chosen = "alpha" }),
            .init(id: "beta", title: "Beta", detail: "", symbol: "command", operation: .perform { chosen = "beta" }),
        ])
        try await fixture.waitForInput()
        fixture.key(11, "b")
        try await fixture.waitForInput()
        fixture.key(36, "\r")
        #expect(chosen == "beta")
    }

    /// A choice step reached by browsing executes its destination only after
    /// the palette has closed and given the keyboard back.
    @Test @MainActor func aChoiceStepExecutesItsDestinationAfterDismissal() async throws {
        let fixture = PaletteFixture()
        defer { fixture.close() }
        var selected = false
        fixture.show([.init(id: "switch_machine", title: "Switch Machine", detail: "Machines", symbol: "desktopcomputer",
                            category: .machines, operation: .choices {
            PaletteChoices(title: "Switch Machine", items: {
                [.init(id: "machine", title: "Build machine", detail: "", symbol: "desktopcomputer", operation: .perform {
                    selected = !fixture.presenter.isPresented && fixture.window.firstResponder === fixture.root
                })]
            })
        })])
        try await fixture.waitForInput()
        fixture.key(125, "\u{f701}") // Switch Machine, after the Tabs group's work browser.
        fixture.key(36, "\r")
        try await fixture.waitForInput()
        fixture.key(36, "\r")
        #expect(selected)
        #expect(!fixture.presenter.isPresented)
    }

    @Test @MainActor func escapeDuringCompositionDoesNotCloseThePalette() async throws {
        let fixture = PaletteFixture()
        defer { fixture.close() }
        fixture.show([])
        try await fixture.waitForInput()
        let editor = try #require(fixture.window.firstResponder as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        fixture.key(53, "\u{1b}", application: true)
        #expect(fixture.presenter.isPresented)
    }

    @Test @MainActor func groupedHomeAndWorkBrowserFitTheSmallestWindow() async throws {
        let fixture = PaletteFixture(size: NSSize(width: 480, height: 300))
        defer { fixture.close() }
        let items = [Action.newTab, .newSplit, .newSplitDown, .openConfig, .increaseFontSize, .closeTab].map {
            PaletteItem(id: $0.rawValue, title: $0.title, detail: $0.paletteCategory.rawValue, symbol: $0.paletteSymbol,
                        shortcut: $0.defaultBind.symbols, category: $0.paletteCategory,
                        destructive: $0 == .closeTab, operation: .perform {})
        } + [PaletteItem(id: "rename_tab", title: "Rename Tab…", detail: "Tabs", symbol: "pencil", operation: .perform {}),
             PaletteItem(id: "work", title: "Koi", detail: "~/koi", symbol: "terminal", kind: .tab, operation: .perform {})]
        let work = PaletteChoices(title: "Open Tabs & Panes", items: { items.filter { $0.kind == .tab } },
                                  placeholder: "Search tabs, programs, directories…")
        for choices in [nil, work] {
            fixture.show(items, choices: choices, maxHeight: 220)
            try await fixture.waitForInput()
            let overlay = try #require(fixture.root.subviews.last)
            let card = try #require(overlay.subviews.first)
            #expect(fixture.root.bounds.contains(card.frame))
            #expect(card.fittingSize.width <= 480)
            #expect(card.fittingSize.height <= 300 - AppDelegate.topRow)
            fixture.presenter.dismiss()
        }
        if ProcessInfo.processInfo.environment["KOI_VISUALS"] != nil {
            let preview = PaletteFixture(size: NSSize(width: 500, height: 600))
            defer { preview.close() }
            for choices in [nil, work] {
                preview.show(items, choices: choices, maxHeight: 500)
                try await preview.waitForInput()
                preview.writePreview(name: choices == nil ? "palette-home" : "palette-work")
                preview.presenter.dismiss()
            }
        }
    }
}

/// Offscreen windows exercise the palette's own focus and native text editing
/// without activation or screen input. Recents are restored after each test.
@MainActor private final class PaletteFixture {
    let window: NSWindow
    let root = PaletteInputView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let presenter = PopupAnchor.Coordinator()
    let oldRecent = UserDefaults.standard.object(forKey: "paletteRecents")

    init(size: NSSize = NSSize(width: 500, height: 400)) {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "paletteRecents")
        root.setFrameSize(size)
        window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeFirstResponder(root)
        presenter.anchor = root
        presenter.centered = true
    }

    func show(_ items: [PaletteItem], query: String = "", choices: PaletteChoices? = nil, maxHeight: CGFloat = 300) {
        presenter.content = AnyView(CommandPalette(query: query, choices: choices, maxHeight: maxHeight, items: { items }))
        presenter.show()
        root.layoutSubtreeIfNeeded()
    }

    /// Await the attached editor's queued focus work, including prompt replacement.
    func waitForInput() async throws {
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.compactMap { field(in: $0) }.first
        }
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            root.layoutSubtreeIfNeeded()
            if let input = field(in: root), let editor = input.currentEditor(), window.firstResponder === editor { return }
        }
        Issue.record("the palette must focus its own text field")
    }

    func key(_ code: UInt16, _ characters: String, application: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: characters,
                                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        if application { NSApp.sendEvent(event) } else { window.sendEvent(event) }
    }

    /// Optional fixture images show the real palette without capturing the desktop.
    func writePreview(name: String) {
        guard let directory = ProcessInfo.processInfo.environment["KOI_VISUALS"],
              let card = root.subviews.last?.subviews.first,
              let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
        card.cacheDisplay(in: card.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + ".png"))
    }

    func close() {
        presenter.dismiss()
        window.close()
        if let oldRecent { UserDefaults.standard.set(oldRecent, forKey: "paletteRecents") }
        else { UserDefaults.standard.removeObject(forKey: "paletteRecents") }
    }
}

private final class PaletteInputView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
