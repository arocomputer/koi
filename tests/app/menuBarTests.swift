import AppKit
import Testing
@testable import Koi

extension SessionTests {
    /// Menus keep every existing action reachable once and route through the
    /// active window/first responder, including actions nested under View → Pane.
    @Test @MainActor func menuBarGroupsActionsWithoutChangingTheirBindings() throws {
        let previous = Config.current
        defer { Config.current = previous }
        Config.current = Config()
        Config.current.binds[.newSplit] = Keybind("j", [.command, .option])
        Config.current.binds[.newTab] = Keybind("", [])
        let menu = AppDelegate.menu()
        #expect(menu.items.map(\.title) == ["Koi", "File", "Edit", "View", "Window", "Help"])
        let pane = try #require(menu.item(withTitle: "View")?.submenu?.item(withTitle: "Pane")?.submenu)
        #expect(pane.items.contains { $0.action == Action.newSplit.selector })
        let all = menuItems(menu)
        for action in Action.allCases {
            let matching = all.filter { $0.action == action.selector }
            #expect(matching.count == 1, "\(action.rawValue) must remain reachable exactly once")
            let item = try #require(matching.first)
            #expect(item.target == nil, "menu commands must follow the active responder chain")
            #expect(item.keyEquivalent == Config.current.bind(action).key)
            #expect(item.keyEquivalentModifierMask == Config.current.bind(action).mods)
        }
        let close = try #require(menu.item(withTitle: "File")?.submenu?.item(withTitle: "Close Window"))
        #expect(close.action == #selector(NSWindow.performClose(_:)) && close.keyEquivalent.isEmpty)
        let help = try #require(menu.item(withTitle: "Help")?.submenu)
        #expect(help.items.contains { $0.action == #selector(AppDelegate.copyDiagnostics(_:)) })
        #expect(help.items.contains { $0.action == #selector(AppDelegate.exportDiagnostics(_:)) })
    }
}

/// Walk nested menu commands without installing menus or displaying native UI.
@MainActor private func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
}
