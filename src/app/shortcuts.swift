import AppKit

/// A keyboard shortcut: the key and the modifiers that trigger an action.
/// Mirrors how AppKit wants a menu item's equivalent, so a `Keybind` maps
/// straight onto `NSMenuItem`.
struct Keybind: Equatable {
    var key: String
    var mods: NSEvent.ModifierFlags

    init(_ key: String, _ mods: NSEvent.ModifierFlags) {
        self.key = key
        self.mods = mods
    }

    /// Parses a trigger like `cmd+shift+d` or `opt+cmd+left`, Ghostty's
    /// config syntax. Returns nil if a part isn't recognized.
    static func parse(_ text: String) -> Keybind? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" { return Keybind("", []) }
        var mods: NSEvent.ModifierFlags = []
        var key: String?
        for raw in text.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "super": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.option)
            default:
                guard let k = equivalent(part) else { return nil }
                key = k
            }
        }
        guard let key else { return nil }
        return Keybind(key, mods)
    }

    /// The shortcut as its Mac symbols, e.g. ⇧⌘D, for showing to people.
    var symbols: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch key {
        case "\u{F702}": s += "←"
        case "\u{F703}": s += "→"
        case "\u{F700}": s += "↑"
        case "\u{F701}": s += "↓"
        case "\r": s += "↩"
        case " ": s += "Space"
        case "\t": s += "⇥"
        default: s += key.uppercased()
        }
        return s
    }

    /// The trigger as it is written in the config, e.g. `cmd+shift+d`.
    var configString: String {
        if key.isEmpty && mods.isEmpty { return "none" }
        var parts: [String] = []
        if mods.contains(.command) { parts.append("cmd") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("alt") }
        parts.append(Keybind.name(for: key))
        return parts.joined(separator: "+")
    }

    /// The config name for a key equivalent (the reverse of `equivalent`).
    private static func name(for key: String) -> String {
        switch key {
        case "\u{F702}": "left"
        case "\u{F703}": "right"
        case "\u{F700}": "up"
        case "\u{F701}": "down"
        case "\r": "enter"
        case " ": "space"
        case "\t": "tab"
        case "+": "plus"
        case "-": "minus"
        case "=": "equal"
        case ",": "comma"
        default: key
        }
    }

    /// A keybind from a captured key-down event, or nil if it has no
    /// modifier (a bare key makes a poor global shortcut).
    static func from(_ event: NSEvent) -> Keybind? {
        var mods: NSEvent.ModifierFlags = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.option) { mods.insert(.option) }
        guard !mods.isEmpty, let first = event.charactersIgnoringModifiers?.first else { return nil }
        return Keybind(String(first).lowercased(), mods)
    }

    /// The `NSMenuItem.keyEquivalent` string for a key name.
    private static func equivalent(_ name: String) -> String? {
        switch name {
        case "left": return "\u{F702}"
        case "right": return "\u{F703}"
        case "up": return "\u{F700}"
        case "down": return "\u{F701}"
        case "enter", "return": return "\r"
        case "space": return " "
        case "tab": return "\t"
        case "plus": return "+"
        case "minus": return "-"
        case "equal": return "="
        case "comma": return ","
        default:
            // A single letter or digit is its own equivalent.
            return name.count == 1 ? name : nil
        }
    }
}

/// Every action a keybind can trigger, named as Ghostty names them in its
/// config (`new_tab`, `new_split`, …). Each carries the method it runs and
/// its default shortcut; the config may rebind any of them (see `Config`).
enum Action: String, CaseIterable {
    case commandPalette = "command_palette"
    case newWindow = "new_window"
    case copy = "copy"
    case selectAll = "select_all"
    case find = "find"
    case fullScreen = "full_screen"
    case clearScrollback = "clear_scrollback"
    case resetTerminal = "reset_terminal"
    case previousPrompt = "previous_prompt"
    case nextPrompt = "next_prompt"
    case insertPath = "insert_path"
    case goDirectory = "go_directory"
    case saveProject = "save_project"
    case openProject = "open_project"
    case showActivity = "show_activity"
    case checkUpdates = "check_updates"
    case diagnostics = "diagnostics"
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case closePane = "close_pane"
    case newSplit = "new_split"
    case newSplitDown = "new_split_down"
    case toggleZoom = "toggle_zoom"
    case focusSplitLeft = "focus_split_left"
    case focusSplitRight = "focus_split_right"
    case focusSplitUp = "focus_split_up"
    case focusSplitDown = "focus_split_down"
    case nextPane = "next_pane"
    case previousPane = "previous_pane"
    case toggleSidebar = "toggle_sidebar"
    case increaseFontSize = "increase_font_size"
    case decreaseFontSize = "decrease_font_size"
    case resetFontSize = "reset_font_size"
    case nextTab = "next_tab"
    case previousTab = "previous_tab"
    case paste = "paste"
    case reloadConfig = "reload_config"
    case openConfig = "open_config"

    var selector: Selector {
        switch self {
        case .newWindow: #selector(AppDelegate.newWindow(_:))
        case .copy: #selector(TerminalView.copy(_:))
        case .selectAll: #selector(NSResponder.selectAll(_:))
        case .find: #selector(TerminalView.performFind(_:))
        case .fullScreen: #selector(AppDelegate.toggleFullScreen(_:))
        case .clearScrollback: #selector(AppDelegate.clearScrollback(_:))
        case .resetTerminal: #selector(AppDelegate.resetTerminal(_:))
        case .previousPrompt: #selector(AppDelegate.previousPrompt(_:))
        case .nextPrompt: #selector(AppDelegate.nextPrompt(_:))
        case .insertPath: #selector(AppDelegate.insertPath(_:))
        case .goDirectory: #selector(AppDelegate.goDirectory(_:))
        case .saveProject: #selector(AppDelegate.saveProject(_:))
        case .openProject: #selector(AppDelegate.openProject(_:))
        case .showActivity: #selector(AppDelegate.showActivity(_:))
        case .checkUpdates: #selector(AppDelegate.checkUpdates(_:))
        case .diagnostics: #selector(AppDelegate.showDiagnostics(_:))
        case .commandPalette: #selector(AppDelegate.showCommandPalette(_:))
        case .newTab: #selector(AppDelegate.newTab(_:))
        case .closeTab: #selector(AppDelegate.closeTab(_:))
        case .closePane: #selector(AppDelegate.closePane(_:))
        case .newSplit: #selector(AppDelegate.splitRight(_:))
        case .newSplitDown: #selector(AppDelegate.splitDown(_:))
        case .toggleZoom: #selector(AppDelegate.zoomPane(_:))
        case .focusSplitLeft: #selector(AppDelegate.focusLeft(_:))
        case .focusSplitRight: #selector(AppDelegate.focusRight(_:))
        case .focusSplitUp: #selector(AppDelegate.focusUp(_:))
        case .focusSplitDown: #selector(AppDelegate.focusDown(_:))
        case .nextPane: #selector(AppDelegate.nextPane(_:))
        case .previousPane: #selector(AppDelegate.previousPane(_:))
        case .toggleSidebar: #selector(AppDelegate.toggleKoiSidebar(_:))
        case .increaseFontSize: #selector(AppDelegate.biggerText(_:))
        case .decreaseFontSize: #selector(AppDelegate.smallerText(_:))
        case .resetFontSize: #selector(AppDelegate.actualSizeText(_:))
        case .nextTab: #selector(AppDelegate.nextTab(_:))
        case .previousTab: #selector(AppDelegate.previousTab(_:))
        case .paste: #selector(TerminalView.paste(_:))
        case .reloadConfig: #selector(AppDelegate.reloadConfig(_:))
        case .openConfig: #selector(AppDelegate.openSettings(_:))
        }
    }

    /// The menu label and the shortcut Koi ships with, before any rebinding.
    var title: String {
        switch self {
        case .newWindow: "New Window"
        case .copy: "Copy"
        case .selectAll: "Select All"
        case .find: "Find in Scrollback"
        case .fullScreen: "Toggle Full Screen"
        case .clearScrollback: "Clear Scrollback"
        case .resetTerminal: "Reset Terminal"
        case .previousPrompt: "Previous Prompt"
        case .nextPrompt: "Next Prompt"
        case .insertPath: "Insert Path…"
        case .goDirectory: "Go to Directory…"
        case .saveProject: "Save Project Layout…"
        case .openProject: "Open Project…"
        case .showActivity: "Show Activity"
        case .checkUpdates: "Check for Updates…"
        case .diagnostics: "Diagnostics…"
        case .commandPalette: "Command Palette…"
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .closePane: "Close Pane"
        case .newSplit: "Split Right"
        case .newSplitDown: "Split Down"
        case .toggleZoom: "Zoom Pane"
        case .focusSplitLeft: "Focus Pane Left"
        case .focusSplitRight: "Focus Pane Right"
        case .focusSplitUp: "Focus Pane Up"
        case .focusSplitDown: "Focus Pane Down"
        case .nextPane: "Next Pane"
        case .previousPane: "Previous Pane"
        case .toggleSidebar: "Toggle Sidebar"
        case .increaseFontSize: "Bigger"
        case .decreaseFontSize: "Smaller"
        case .resetFontSize: "Actual Size"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .paste: "Paste"
        case .reloadConfig: "Reload Config"
        case .openConfig: "Settings…"
        }
    }

    var defaultBind: Keybind {
        switch self {
        case .newWindow: Keybind("n", .command)
        case .copy: Keybind("c", .command)
        case .selectAll: Keybind("a", .command)
        case .find: Keybind("f", .command)
        case .fullScreen: Keybind("f", [.command, .control])
        case .clearScrollback: Keybind("k", .command)
        case .previousPrompt: Keybind("\u{F700}", .command)
        case .nextPrompt: Keybind("\u{F701}", .command)
        case .insertPath: Keybind("i", [.command, .control])
        case .goDirectory: Keybind("g", [.command, .shift])
        case .resetTerminal, .saveProject, .openProject, .showActivity, .checkUpdates, .diagnostics: Keybind("", [])
        case .commandPalette: Keybind("p", .command)
        case .newTab: Keybind("t", .command)
        case .closeTab: Keybind("w", [.command, .shift])
        case .closePane: Keybind("w", .command)
        case .newSplit: Keybind("d", .command)
        case .newSplitDown: Keybind("d", [.command, .shift])
        case .toggleZoom: Keybind("\r", [.command, .shift])
        case .focusSplitLeft: Keybind("\u{F702}", [.command, .option])
        case .focusSplitRight: Keybind("\u{F703}", [.command, .option])
        case .focusSplitUp: Keybind("\u{F700}", [.command, .option])
        case .focusSplitDown: Keybind("\u{F701}", [.command, .option])
        case .nextPane: Keybind("]", .command)
        case .previousPane: Keybind("[", .command)
        case .toggleSidebar: Keybind("s", .command)
        case .increaseFontSize: Keybind("+", .command)
        case .decreaseFontSize: Keybind("-", .command)
        case .resetFontSize: Keybind("0", .command)
        case .nextTab: Keybind("]", [.command, .shift])
        case .previousTab: Keybind("[", [.command, .shift])
        case .paste: Keybind("v", .command)
        case .reloadConfig: Keybind(",", [.command, .shift])
        case .openConfig: Keybind(",", .command)
        }
    }
}
