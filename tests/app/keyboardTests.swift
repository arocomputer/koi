import AppKit
import GhosttyVt
import Testing
@testable import Koi

/// Pin the bytes sent to a shell, including the boundary between Mac shortcuts
/// and the extended keys a terminal program explicitly asks to receive.
@Suite @MainActor struct KeyboardTests {
    @Test func macEditingKeysUseGhosttysNaturalEditingDefaults() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        let bindings: [(UInt16, NSEvent.ModifierFlags, [UInt8])] = [
            (123, .command, [0x01]), (124, .command, [0x05]), (51, .command, [0x15]),
            (123, .option, [0x1b, 0x62]), (124, .option, [0x1b, 0x66]),
            (123, [.command, .capsLock, .function], [0x01]),
        ]
        for (key, modifiers, expected) in bindings {
            let input = event(key, modifiers)
            #expect(keyboard.encode(input, action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == expected)
            #expect(keyboard.encode(input, action: GHOSTTY_KEY_ACTION_REPEAT, text: nil, terminal: terminal) == expected)
            #expect(keyboard.encode(input, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal).isEmpty)
        }
    }

    @Test func unboundCommandCombinationsNeverSendEscapeFragmentsToAShell() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        for (key, modifiers): (UInt16, NSEvent.ModifierFlags) in [
            (36, [.command, .option]), (76, [.command, .option]),
            (123, [.command, .shift]), (126, .command), (0, .command),
        ] {
            let input = event(key, modifiers)
            #expect(keyboard.encode(input, action: GHOSTTY_KEY_ACTION_PRESS, text: input.keyText, terminal: terminal).isEmpty)
            #expect(keyboard.encode(input, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal).isEmpty)
        }
    }

    /// Control letters, Shift-Tab, Option-Delete, Home/End and application
    /// cursor arrows are terminal input in legacy mode, as in any terminal.
    @Test func everydayEditingAndControlKeysRemainTerminalInput() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        for (code, text, byte): (UInt16, String, UInt8) in [(8, "c", 3), (2, "d", 4), (6, "z", 26), (13, "w", 23), (32, "u", 21)] {
            #expect(keyboard.encode(event(code, .control, text), action: GHOSTTY_KEY_ACTION_PRESS, text: text, terminal: terminal) == [byte])
        }
        #expect(keyboard.encode(event(0, .option, "å"), action: GHOSTTY_KEY_ACTION_PRESS, text: "å", terminal: terminal) == bytes("å"))
        #expect(keyboard.encode(event(48, .shift, "\t"), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == bytes("\u{1b}[Z"))
        #expect(keyboard.encode(event(51, .option), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == [27, 127])
        #expect(keyboard.encode(event(115, []), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == bytes("\u{1b}[H"))
        #expect(keyboard.encode(event(119, []), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == bytes("\u{1b}[F"))
        #expect(keyboard.encode(event(123, []), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == bytes("\u{1b}[D"))
        terminal.write(Array("\u{1b}[?1h".utf8))
        #expect(keyboard.encode(event(123, []), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == bytes("\u{1b}OD"))
    }

    @Test func kittyNegotiationPreservesExtendedKeysAndReleases() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        terminal.write(Array("\u{1b}[>11u".utf8))
        let enter = event(36, [.command, .option], "\r")
        #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == bytes("\u{1b}[13;11u"))
        #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal) == bytes("\u{1b}[13;11:3u"))
        #expect(keyboard.encode(event(36, .shift, "\r"), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == bytes("\u{1b}[13;2u"))
        terminal.write(Array("\u{1b}[<u".utf8))
        #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal).isEmpty)
    }

    @Test func shiftEnterStaysDistinctFromSubmitAcrossProtocolChanges() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        let enter = event(36, [], "\r")
        let newline = event(36, .shift, "\r")
        let modes: [(String, String)] = [
            ("", "\u{1b}[27;2;13~"),
            ("\u{1b}[>4;2m", "\u{1b}[27;2;13~"),
            ("\u{1b}[>1u", "\u{1b}[13;2u"),
            ("\u{1b}[<u\u{1b}[>4;0m", "\u{1b}[27;2;13~"),
        ]
        for (sequence, pressed) in modes {
            terminal.write(bytes(sequence))
            #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal) == [0x0d])
            for action in [GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_ACTION_REPEAT] {
                #expect(keyboard.encode(newline, action: action, text: newline.keyText, terminal: terminal) == bytes(pressed))
            }
            #expect(keyboard.encode(newline, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal).isEmpty)
        }
    }

    /// `alt` sends the base-layout key with an Alt prefix (or Kitty modifier);
    /// `automatic` and `text` keep the native composed text. Mac editing
    /// bindings and caller-supplied IME commits win under every policy.
    @Test func optionKeyPoliciesChooseBetweenAltAndNativeText() throws {
        let terminal = VTTerminal(cols: 80, rows: 24)
        let input = event(0, .option, "å")
        let plain = try #require(input.characters(byApplyingModifiers: []))
        #expect(TerminalKeyboard.usesOptionAsAlt(input, optionKey: .alt))
        #expect(!TerminalKeyboard.usesOptionAsAlt(input, optionKey: .automatic))
        #expect(!TerminalKeyboard.usesOptionAsAlt(input, optionKey: .text))
        #expect(TerminalKeyboard().encode(input, action: GHOSTTY_KEY_ACTION_PRESS, text: "å", terminal: terminal,
                                          optionKey: .alt) == bytes("\u{1b}" + plain))
        for policy in [Config.OptionKey.automatic, .text] {
            #expect(TerminalKeyboard().encode(input, action: GHOSTTY_KEY_ACTION_PRESS, text: "å", terminal: terminal,
                                              optionKey: policy) == bytes("å"))
        }
        let committed = "日本語"
        #expect(TerminalKeyboard().encode(input, action: GHOSTTY_KEY_ACTION_PRESS, text: committed, terminal: terminal,
                                          optionKey: .alt) == bytes(committed))

        terminal.write(bytes("\u{1b}[>11u"))
        let codepoint = try #require(plain.unicodeScalars.first).value
        let alt = TerminalKeyboard()
        #expect(alt.encode(input, action: GHOSTTY_KEY_ACTION_PRESS, text: "å", terminal: terminal, optionKey: .alt) == bytes("\u{1b}[\(codepoint);3u"))
        #expect(alt.encode(input, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal, optionKey: .alt) == bytes("\u{1b}[\(codepoint);3:3u"))
        let native = TerminalKeyboard()
        #expect(native.encode(input, action: GHOSTTY_KEY_ACTION_PRESS, text: "å", terminal: terminal, optionKey: .text) == bytes("\u{1b}[\(codepoint)u"))
        #expect(native.encode(input, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal, optionKey: .text) == bytes("\u{1b}[\(codepoint);1:3u"))
        for policy in [Config.OptionKey.automatic, .alt, .text] {
            #expect(TerminalKeyboard().encode(event(123, .option), action: GHOSTTY_KEY_ACTION_PRESS, text: nil,
                                              terminal: terminal, optionKey: policy) == [0x1b, 0x62])
        }
    }

    @Test func modifierKeysReportOnlyWhenRequestedAndTrackLeftAndRightSeparately() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        let leftShift = flags(0x38, .shift, 0x02)
        #expect(keyboard.flagsChanged(leftShift, terminal: terminal).isEmpty)
        terminal.write(bytes("\u{1b}[>3u"))
        #expect(keyboard.flagsChanged(leftShift, terminal: terminal).isEmpty) // not report-all
        #expect(!keyboard.isHeld(0x38))
        terminal.write(bytes("\u{1b}[>11u"))
        let rightShift = flags(0x3c, .shift, 0x06)
        let left = keyboard.flagsChanged(flags(0x38, .shift, 0x02), terminal: terminal)
        let right = keyboard.flagsChanged(rightShift, terminal: terminal)
        #expect(left == bytes("\u{1b}[57441;2u"))
        #expect(right == bytes("\u{1b}[57447;2u"))
        #expect(keyboard.isHeld(0x38) && keyboard.isHeld(0x3c))
        // Left released while right stays down: the flag is still set.
        #expect(keyboard.flagsChanged(flags(0x38, .shift, 0x04), terminal: terminal) == bytes("\u{1b}[57441;2:3u"))
        #expect(keyboard.isHeld(0x3c) && !keyboard.isHeld(0x38))
        #expect(keyboard.flagsChanged(flags(0x3c, [], 0), terminal: terminal) == bytes("\u{1b}[57447;1:3u"))
    }

    /// A press an input method or menu consumed was never encoded, so it has
    /// no release; repeats do not stack; focus loss releases what is held once.
    @Test func onlyEncodedPressesAreReleasedAndFocusLossReleasesThemOnce() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        terminal.write(bytes("\u{1b}[>11u"))
        let enter = event(36, [], "\r")
        #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal).isEmpty)
        _ = keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: terminal)
        let a = event(0, [], "a")
        _ = keyboard.encode(a, action: GHOSTTY_KEY_ACTION_PRESS, text: "a", terminal: terminal)
        for _ in 0..<100 { _ = keyboard.encode(a, action: GHOSTTY_KEY_ACTION_REPEAT, text: "a", terminal: terminal) }
        #expect(keyboard.isHeld(36) && keyboard.isHeld(0))
        #expect(keyboard.releaseAll(terminal: terminal) == bytes("\u{1b}[13;1:3u\u{1b}[97;1:3u"))
        #expect(!keyboard.isHeld(36) && !keyboard.isHeld(0))
        #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, terminal: terminal).isEmpty)
        #expect(keyboard.releaseAll(terminal: terminal).isEmpty)
    }

    @Test func longAndNulContainingTextIsEncodedWhole() {
        let keyboard = TerminalKeyboard()
        let terminal = VTTerminal(cols: 80, rows: 24)
        let long = String(repeating: "é", count: 200)
        #expect(keyboard.encode(event(0, [], "é"), action: GHOSTTY_KEY_ACTION_PRESS, text: long, terminal: terminal) == bytes(long))
        #expect(keyboard.encode(event(0, [], "a"), action: GHOSTTY_KEY_ACTION_PRESS, text: "a\0b", terminal: terminal) == bytes("a\0b"))
    }

    /// A reattached pane must encode input using the restored terminal modes,
    /// then pick up mode changes as the program exits or enters another screen.
    @Test func reattachRestoresKeyboardPasteAndCursorModes() throws {
        let old = VTTerminal(cols: 80, rows: 24)
        old.write(Array("\u{1b}[>1u\u{1b}[?2004h\u{1b}[?1h".utf8))
        let restored = try #require(VTTerminal(snapshot: old.snapshot()))
        let keyboard = TerminalKeyboard()
        let enter = event(36, .shift, "\r")
        #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: restored) == bytes("\u{1b}[13;2u"))
        #expect(restored.mode(2004))
        #expect(TerminalView.pasteBytes("a\nb", bracketed: restored.mode(2004)) == bytes("\u{1b}[200~a\nb\u{1b}[201~"))
        restored.write(Array("\u{1b}[<u\u{1b}[?2004l".utf8))
        #expect(keyboard.encode(enter, action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: restored) == bytes("\u{1b}[27;2;13~"))
        #expect(keyboard.encode(event(123, []), action: GHOSTTY_KEY_ACTION_PRESS, text: nil, terminal: restored) == bytes("\u{1b}OD"))
        #expect(TerminalView.pasteBytes("a\nb", bracketed: restored.mode(2004)) == bytes("a\rb"))
    }

    private func flags(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ device: UInt) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                         modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers.rawValue | device),
                         timestamp: 1, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }

    private func event(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ text: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code)!
    }

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
}

@MainActor extension SessionTests {
    @Test @MainActor func configuredShortcutsTakePriorityOverTerminalEditing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = TerminalView(pane: "keyboard-test", at: .local)
        window.contentView = terminal
        window.makeFirstResponder(terminal)
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu; window.close() }
        let target = KeyboardMenuTarget()
        let menu = NSMenu()
        let root = NSMenuItem()
        let submenu = NSMenu()
        root.submenu = submenu
        menu.addItem(root)
        NSApp.mainMenu = menu
        // Menu actions, including Command-P, take priority over terminal
        // editing and extended key reporting.
        let shortcuts: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("\u{f702}", 123, .command), ("\u{f702}", 123, .control), ("p", 35, .command),
        ]
        for (key, code, modifiers) in shortcuts {
            submenu.removeAllItems()
            let item = NSMenuItem(title: "Test action", action: #selector(KeyboardMenuTarget.run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            submenu.addItem(item)
            let input = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            let before = target.count
            #expect(terminal.performKeyEquivalent(with: input))
            #expect(target.count == before + 1)
        }
    }
}

/// An explicit menu target lets the test observe normal menu dispatch.
@MainActor private final class KeyboardMenuTarget: NSObject {
    var count = 0
    @objc func run(_ sender: Any?) { count += 1 }
}
