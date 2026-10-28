import AppKit
import Testing
@testable import Koi

/// The config's keybind triggers must parse the way people write them.
@Test func parsesKeybindTriggers() {
    #expect(Keybind.parse("cmd+t") == Keybind("t", .command))
    #expect(Keybind.parse("cmd+shift+d") == Keybind("d", [.command, .shift]))
    #expect(Keybind.parse("opt+cmd+left") == Keybind("\u{F702}", [.command, .option]))
    #expect(Keybind.parse("ctrl+a") == Keybind("a", .control))
    // Order and casing don't matter.
    #expect(Keybind.parse("SHIFT+CMD+t") == Keybind("t", [.command, .shift]))
    // Nonsense keys are rejected rather than silently bound.
    #expect(Keybind.parse("cmd+notakey") == nil)
    #expect(Keybind.parse("cmd") == nil)
}

/// Every default shortcut must serialize to config text that parses back to
/// the same bind, so the Settings recorder and the file agree.
@Test func keybindsRoundTripThroughConfigText() {
    for action in Action.allCases {
        let bind = action.defaultBind
        #expect(Keybind.parse(bind.configString) == bind, "\(action.rawValue): \(bind.configString)")
    }
}

/// Collision checks include untouched defaults and exclude only the edited action.
@Test func shortcutConflictsIncludeDefaultsAndConfiguredOverrides() {
    var config = Config()
    #expect(config.conflicts(for: Action.newTab.defaultBind, excluding: .newTab).isEmpty)
    #expect(config.conflicts(for: Action.newTab.defaultBind, excluding: .newSplit) == [.newTab])
    config.binds[.newSplit] = Action.newTab.defaultBind
    #expect(config.conflicts(for: Action.newTab.defaultBind) == [.newTab, .newSplit])
    #expect(config.conflicts(for: Action.newTab.defaultBind, excluding: .newTab) == [.newSplit])
    let loaded = Config.parse("keybind = cmd+t = new_split")
    #expect(loaded.bind(.newSplit) == Action.newTab.defaultBind)
    #expect(loaded.issues.contains { $0.contains("new_tab") && $0.contains("new_split") && $0.contains("cmd+t") })
}
