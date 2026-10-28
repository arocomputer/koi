import AppKit

/// The macOS menu bar uses the same actions and configured shortcuts as Koi's
/// palette. In-window menus keep their own glass presentation in menu.swift.
extension AppDelegate {
    /// Register native menu roles so Help search, Services and open-window lists work.
    static func installMenu() {
        let main = menu()
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = main.item(withTitle: "Help")?.submenu
        NSApp.servicesMenu = main.items.first?.submenu?.item(withTitle: "Services")?.submenu
    }

    /// Build without installing, allowing offscreen checks of action routing and rebinding.
    static func menu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            parent.submenu = menu
            return parent
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        func action(_ action: Action, title: String? = nil) -> NSMenuItem {
            let bind = Config.current.bind(action)
            return item(title ?? action.title, action.selector, bind.key, bind.mods)
        }
        let name = Paths.isDev ? "Koid" : "Koi"
        main.addItem(submenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            action(.openConfig),
            action(.reloadConfig),
            action(.checkUpdates),
            .separator(),
            submenu("Services", []),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            action(.newWindow),
            action(.newTab),
            .separator(),
            action(.goDirectory),
            action(.insertPath),
            .separator(),
            action(.openProject),
            action(.saveProject),
            .separator(),
            action(.closePane),
            action(.closeTab),
            // Keep Close Tab's existing shortcut; closing a window only detaches.
            item("Close Window", #selector(NSWindow.performClose(_:))),
        ]))
        main.addItem(submenu("Edit", [
            action(.copy),
            action(.paste),
            .separator(),
            action(.selectAll),
            .separator(),
            action(.find),
            .separator(),
            action(.clearScrollback),
            action(.resetTerminal),
        ]))
        main.addItem(submenu("View", [
            action(.commandPalette),
            .separator(),
            submenu("Pane", [
                action(.newSplit),
                action(.newSplitDown),
                .separator(),
                action(.toggleZoom),
                .separator(),
                action(.focusSplitLeft),
                action(.focusSplitRight),
                action(.focusSplitUp),
                action(.focusSplitDown),
                .separator(),
                action(.nextPane),
                action(.previousPane),
            ]),
            .separator(),
            action(.resetFontSize, title: "Reset Font Size"),
            action(.increaseFontSize, title: "Increase Font Size"),
            action(.decreaseFontSize, title: "Decrease Font Size"),
            .separator(),
            action(.toggleSidebar),
            action(.showActivity),
            .separator(),
            action(.previousPrompt),
            action(.nextPrompt),
            .separator(),
            action(.fullScreen),
        ]))
        let numbered = (1...9).map { number -> NSMenuItem in
            let item = item("Tab \(number)", #selector(selectNumberedTab(_:)), "\(number)")
            item.tag = number
            return item
        }
        main.addItem(submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            action(.nextTab),
            action(.previousTab),
            .separator(),
        ] + numbered + [
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ]))
        main.addItem(submenu("Help", [
            action(.diagnostics),
            .separator(),
            item("Open Logs…", #selector(openLogs(_:))),
            .separator(),
            item("Copy Diagnostics", #selector(copyDiagnostics(_:))),
            item("Export Diagnostics…", #selector(exportDiagnostics(_:))),
        ]))
        return main
    }
}
