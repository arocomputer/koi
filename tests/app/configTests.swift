import AppKit
import CoreText
import Foundation
import Testing
@testable import Koi

/// Pure parsing and font metric checks avoid touching process-wide settings.
@Suite @MainActor struct ConfigTests {
    /// Every typed setting parses from its config text and prints back the
    /// same canonical text, so Settings edits and the file agree.
    @Test func typedSettingsRoundTripThroughConfigText() {
        let entries = [
            ("animation", "natural"), ("reduce-transparency", "true"),
            ("line-height", "1.5"), ("option-key", "alt"), ("show-pane-headers", "false"),
            ("compact-panes", "true"), ("focus-follows-mouse", "true"),
            ("fade-inactive-panes", "true"), ("notify-blocked", "true"), ("notify-done", "true"),
            ("notify-error", "true"), ("quiet-when-focused", "false"), ("startup-command", "env TERM=xterm zsh"),
            ("scrollback-mb", "16"), ("cursor-style", "hollow"), ("cursor-opacity", "0.5"),
            ("cursor-height", "0.4"), ("font-family", "Menlo"), ("font-size", "72"), ("tabs", "right"),
            ("background-opacity", "0"),
        ]
        let config = Config.parse(entries.map { "\($0.0) = \($0.1)" }.joined(separator: "\n"))
        #expect(config.issues.isEmpty)
        for (key, value) in entries { #expect(config.value(for: key) == value, "\(key)") }
        #expect(config.motion == .natural && config.optionKey == .alt)
        #expect(Config.parse("animation = off\noption-key = text").motion == .off)
        #expect(Config.parse("animation = off\noption-key = text").optionKey == .text)
        #expect(Config.parse("tabs = left").value(for: "tabs") == "side")
    }

    @Test func lastNormalValueWinsAndInvalidLastValueRestoresDefault() {
        let config = Config.parse("""
        font-size = 20
        tabs = top
        cursor-style = bar
        font-size = 6
        tabs = nonsense
        cursor-style = invalid
        """)
        #expect(config.fontSize == 6)
        #expect(config.tabs == .side)
        #expect(config.cursorStyle == nil)
        #expect(config.issues.count == 2)
        #expect(config.issues.contains { $0.contains("Line 5") && $0.contains("tabs") })
        #expect(config.issues.contains { $0.contains("Line 6") && $0.contains("cursor-style") })
        let repaired = Config.parse("font-size = invalid\nfont-size = 20")
        #expect(repaired.fontSize == 20 && repaired.issues.count == 1)
    }

    @Test func nonfiniteAndOutOfRangeNumbersKeepDefaults() {
        for key in ["font-size", "background-opacity", "cursor-opacity", "cursor-height", "line-height"] {
            for value in ["nan", "inf", "-inf", "1e9999", "-1", "10000"] {
                let config = Config.parse("\(key) = \(value)")
                #expect(config.value(for: key) == Config().value(for: key), "\(key) = \(value)")
                #expect(config.issues.count == 1 && config.issues[0].contains(key))
            }
        }
        for value in ["0", "33", "1025", "1.5", "nan", "999999999999999999999999999"] {
            let config = Config.parse("scrollback-mb = \(value)")
            #expect(config.scrollbackMB == 32 && config.issues.count == 1)
        }
    }

    @Test func malformedAndUnknownSettingsProduceReadableDiagnostics() {
        let config = Config.parse("""
        # comment
        missing equals
        unknown-setting = true
        notify-done = maybe
        cursor-style = triangle
        keybind = cmd+t = not_an_action
        keybind = cmd+t+x = new_tab
        keybind = cmd++t = new_tab
        """)
        #expect(config.issues.count == 7)
        #expect(config.binds.isEmpty && !config.notifyDone && config.cursorStyle == nil)
        #expect(config.issues.contains { $0.contains("expected key = value") })
        #expect(config.issues.contains { $0.contains("unknown-setting") })
        #expect(config.issues.contains { $0.contains("notify-done") && $0.contains("true or false") })
    }

    @Test func emptyOptionalOverridesRoundTripWithoutDiagnostics() {
        let keys = ["font-family", "cursor-style", "startup-command"]
        let config = Config.parse(keys.map { "\($0) =" }.joined(separator: "\n"))
        #expect(config.issues.isEmpty)
        for key in keys { #expect(config.value(for: key).isEmpty) }
    }

    @Test func lineHeightChangesCellsWithoutScalingFontOrCursorBox() {
        let normal = FontMetrics(size: 13, scale: 2, lineHeight: 1)
        let spaced = FontMetrics(size: 13, scale: 2, lineHeight: 1.5)
        #expect(spaced.cellHeight > normal.cellHeight && spaced.cellWidth == normal.cellWidth)
        #expect(CTFontGetSize(spaced.regular) == CTFontGetSize(normal.regular))
        #expect(CGFloat(spaced.cellHeight) - spaced.leading == CGFloat(normal.cellHeight) - normal.leading)
        #expect(spaced.descent - normal.descent == (spaced.lineSpacing / 2).rounded())
        #expect(spaced.underlinePosition - normal.underlinePosition == spaced.descent - normal.descent)
        #expect(FontMetrics(size: 13, scale: 2, lineHeight: .nan).cellHeight == normal.cellHeight)
        #expect(CTFontGetSize(FontMetrics(size: 100, scale: 1).regular) == 72)
        #expect(CTFontGetSize(FontMetrics(size: 1, scale: 1).regular) == 6)
    }
}

/// These join the existing serialized suite because integration fixtures also
/// change KOI_DIR. No server is started by any configuration persistence check.
extension SessionTests {
    @Test func configEditsCanonicalizeDuplicatesAndPreserveUnrelatedLines() throws {
        try withTemporaryConfig { _ in
            let original = "# keep\nfont-size = 10\nkeybind = cmd+shift+k = new_tab\nfont-size=22\nstartup-command = echo x=y\n"
            try original.write(to: Paths.config, atomically: true, encoding: .utf8)
            #expect(Config.load().fontSize == 22)
            try Config.set("font-size", "014.0")
            #expect(try String(contentsOf: Paths.config, encoding: .utf8) == "# keep\nfont-size = 14\nkeybind = cmd+shift+k = new_tab\nstartup-command = echo x=y\n")
            #expect(Config.load().fontSize == 14)
            try Config.reset(key: "font-size")
            #expect(try String(contentsOf: Paths.config, encoding: .utf8) == "# keep\nkeybind = cmd+shift+k = new_tab\nstartup-command = echo x=y\n")
            #expect(Config.load().fontSize == 13)
        }
    }

    @Test func normalResetRemovesAllOccurrencesWithoutTouchingCommentedDefaults() throws {
        try withTemporaryConfig { _ in
            let original = "# tabs = right\ntabs = top\nfont-size = 18\ntabs=right\n"
            try original.write(to: Paths.config, atomically: true, encoding: .utf8)
            try Config.reset(key: "tabs")
            #expect(try String(contentsOf: Paths.config, encoding: .utf8) == "# tabs = right\nfont-size = 18\n")
            #expect(Config.load().tabs == .side)
        }
    }

    @Test func keybindEditsRejectConflictsAndResetAllActionOverrides() throws {
        try withTemporaryConfig { _ in
            let original = "# keep\nkeybind = cmd+shift+k = new_tab\nkeybind = invalid = new_tab\nkeybind = cmd+shift+j = new_tab\nfont-size = 15\n"
            try original.write(to: Paths.config, atomically: true, encoding: .utf8)
            #expect(Config.load().bind(.newTab) == Keybind("j", [.command, .shift]))
            #expect(throws: Config.EditError.self) { try Config.setKeybind(.newTab, Action.newSplit.defaultBind) }
            #expect(try String(contentsOf: Paths.config, encoding: .utf8) == original)
            let bind = Keybind("k", [.command, .shift])
            try Config.setKeybind(.newTab, bind)
            #expect(Config.load().bind(.newTab) == bind)
            #expect(try String(contentsOf: Paths.config, encoding: .utf8) == "# keep\nfont-size = 15\n\nkeybind = cmd+shift+k = new_tab")
            try Config.resetKeybind(.newTab)
            #expect(Config.load().bind(.newTab) == Action.newTab.defaultBind)
            #expect(try String(contentsOf: Paths.config, encoding: .utf8) == "# keep\nfont-size = 15\n")
        }
    }

    @Test func clearingABindingPersistsWithoutCollidingWithOtherUnassignedActions() throws {
        try withTemporaryConfig { _ in
            try Config.setKeybind(.newTab, Keybind("", []))
            try Config.setKeybind(.newSplit, Keybind("", []))
            let loaded = Config.load()
            #expect(loaded.bind(.newTab).key.isEmpty)
            #expect(loaded.bind(.newSplit).key.isEmpty)
            #expect(loaded.conflicts(for: Keybind("", [])).isEmpty)
            #expect(loaded.issues.isEmpty)
            try Config.resetKeybind(.newTab)
            #expect(Config.load().bind(.newTab) == Action.newTab.defaultBind)
            #expect(Config.load().bind(.newSplit).key.isEmpty)
        }
    }

    @Test func configEditsPropagateReadAndDirectoryCreationFailures() throws {
        try withTemporaryConfig { dir in
            try FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
            #expect(!Config.load().issues.isEmpty)
            #expect(throws: (any Error).self) { try Config.set("font-size", "15") }
            #expect(throws: (any Error).self) { try Config.reset(key: "font-size") }
            #expect(throws: (any Error).self) { try Config.setKeybind(.newTab, Keybind("k", [.command, .shift])) }
            #expect(throws: (any Error).self) { try Config.resetKeybind(.newTab) }
            try FileManager.default.removeItem(at: Paths.config)
            try FileManager.default.removeItem(at: dir)
            try "not a directory".write(to: dir, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try Config.set("font-size", "15") }
            #expect(try String(contentsOf: dir, encoding: .utf8) == "not a directory")
        }
    }

    @Test(.enabled(if: geteuid() != 0)) func configAtomicWriteFailureThrowsAndPreservesTheOriginalFile() throws {
        try withTemporaryConfig { dir in
            let original = "font-size = 15\n"
            try original.write(to: Paths.config, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            #expect(throws: (any Error).self) { try Config.set("font-size", "16") }
            #expect(try String(contentsOf: Paths.config, encoding: .utf8) == original)
        }
    }

    @Test func missingConfigIsNormalButInvalidEditsNeverCreateAFile() throws {
        try withTemporaryConfig { _ in
            #expect(Config.load().issues.isEmpty)
            #expect(throws: Config.EditError.self) { try Config.set("font-size", "nan") }
            #expect(throws: Config.EditError.self) { try Config.set("startup-command", "echo one\necho two") }
            #expect(!FileManager.default.fileExists(atPath: Paths.config.path))
            try Config.set("font-size", "6")
            #expect(Config.load().fontSize == 6)
        }
    }

    @Test func invalidUTF8CannotBeOverwrittenByASettingsEdit() throws {
        try withTemporaryConfig { _ in
            let invalid = Data([0xff, 0xfe, 0x00])
            try invalid.write(to: Paths.config)
            #expect(!Config.load().issues.isEmpty)
            #expect(throws: (any Error).self) { try Config.set("font-size", "15") }
            #expect(try Data(contentsOf: Paths.config) == invalid)
        }
    }
}

/// Gives a synchronous check its own config and restores the exact environment.
private func withTemporaryConfig(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("koi-config-\(UUID().uuidString)")
    try Paths.ensurePrivateDirectory(dir)
    let previous = ProcessInfo.processInfo.environment["KOI_DIR"]
    setenv("KOI_DIR", dir.path, 1)
    defer {
        if let previous { setenv("KOI_DIR", previous, 1) } else { unsetenv("KOI_DIR") }
        try? FileManager.default.removeItem(at: dir)
    }
    try body(dir)
}
