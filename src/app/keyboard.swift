import AppKit
import GhosttyVt

/// Encodes pane input using the program's current keyboard protocol. Mac text
/// editing bindings precede encoding; unbound Command keys stay out of shells.
/// Modified terminal keys keep Ghostty's encoding, including Shift+Enter.
///
/// The keyboard remembers which physical keys it actually encoded as pressed.
/// A release is encoded only for those keys, so keys consumed by an input
/// method, menu or app shortcut never produce a stray release, and
/// `releaseAll` can let go of whatever the program still believes is held
/// (e.g. when the pane loses focus).
@MainActor final class TerminalKeyboard {
    private var encoder: GhosttyKeyEncoder?
    private var event: GhosttyKeyEvent?
    /// Keys encoded as pressed and not yet released, in press order.
    private var held: [(code: UInt16, unshifted: UInt32, textOption: Bool)] = []

    init() {
        ghostty_key_encoder_new(nil, &encoder)
        ghostty_key_event_new(nil, &event)
    }

    isolated deinit {
        ghostty_key_encoder_free(encoder)
        ghostty_key_event_free(event)
    }

    /// Whether the key with this `NSEvent.keyCode` was encoded as pressed and
    /// has not been released. AppKit withholds key-up events while Command is
    /// down; callers use this to forward only the releases that matter.
    func isHeld(_ keyCode: UInt16) -> Bool { held.contains { $0.code == keyCode } }

    /// Whether native Option dead-key interpretation should be bypassed for Alt.
    /// Callers must still let an active IME finish its marked-text composition.
    static func usesOptionAsAlt(_ input: NSEvent, optionKey: Config.OptionKey? = nil) -> Bool {
        (optionKey ?? Config.current.optionKey) == .alt && input.modifierFlags.contains(.option)
    }

    /// Encodes a key press, repeat or release. Automatic keeps existing behavior;
    /// Alt uses layout text without Option, while text consumes Option even in Kitty.
    /// IME commits differing from the key's text are never rewritten.
    func encode(_ input: NSEvent, action: GhosttyKeyAction, text: String?, terminal: VTTerminal,
                optionKey: Config.OptionKey? = nil) -> [UInt8] {
        var policy = optionKey ?? Config.current.optionKey
        if action == GHOSTTY_KEY_ACTION_RELEASE {
            return encodeKey(input.keyCode, action: action, mods: TerminalView.mods(input.modifierFlags),
                             consumed: 0, unshifted: 0, text: nil, terminal: terminal, optionKey: policy)
        }
        let modifiers = input.modifierFlags.intersection([.command, .control, .option, .shift])
        // Ghostty's macOS "natural text editing" defaults are bindings, so
        // they apply even when a program has enabled an extended protocol.
        if let binding = Self.editingBinding(input.keyCode, modifiers) {
            return binding
        }
        var kitty: GhosttyKittyKeyFlags = 0
        ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &kitty)
        if kitty == 0 {
            // Function keys otherwise encode Super as xterm modifiers that a
            // shell's line editor can print literally (e.g. ";9D").
            if modifiers.contains(.command) { return [] }
        }
        let mods = TerminalView.mods(input.modifierFlags)
        if policy == .alt, let text, text != input.keyText {
            // A supplied composition/autocorrection commit is already native
            // text. Do not let Ghostty reinterpret it as the physical Alt key.
            policy = .automatic
        }
        var text = text
        let alt = Self.usesOptionAsAlt(input, optionKey: policy)
        if alt, text == nil || text == input.keyText,
           let plain = input.characters(byApplyingModifiers: input.modifierFlags.intersection([.shift, .capsLock])),
           let first = plain.unicodeScalars.first, first.value >= 0x20, first.value != 0x7f,
           !(0xF700...0xF8FF).contains(first.value) {
            text = plain
        }
        // Layout text consumes Shift. Only native text consumes Option; Alt
        // remains available for legacy escape prefixes and Kitty modifiers.
        let consumed = text == nil ? 0 : mods & GhosttyMods(GHOSTTY_MODS_SHIFT | (alt ? 0 : GHOSTTY_MODS_ALT))
        return encodeKey(input.keyCode, action: action, mods: mods, consumed: consumed,
                         unshifted: input.unshiftedCodepoint, text: text, terminal: terminal, optionKey: policy)
    }

    /// Encodes a modifier key change from a `.flagsChanged` event. The
    /// physical left/right device masks decide press versus release, so
    /// releasing one Shift while the other is down is still a release. The
    /// encoder emits nothing unless the program asked Kitty to report all keys.
    func flagsChanged(_ input: NSEvent, terminal: VTTerminal) -> [UInt8] {
        guard let (flag, device) = Self.modifierKeys[input.keyCode] else { return [] }
        let raw = input.modifierFlags.rawValue
        let pressed = input.modifierFlags.contains(flag) && (device == 0 || raw & device != 0)
        var mods = TerminalView.mods(input.modifierFlags)
        for (flag, side, device) in Self.sides where input.modifierFlags.contains(flag) && raw & device != 0 {
            mods |= side
        }
        return encodeKey(input.keyCode, action: pressed ? GHOSTTY_KEY_ACTION_PRESS : GHOSTTY_KEY_ACTION_RELEASE,
                         mods: mods, consumed: 0, unshifted: 0, text: nil, terminal: terminal)
    }

    /// Encodes releases for every key still held and forgets them, so a
    /// program does not see keys stuck down after focus is lost.
    func releaseAll(terminal: VTTerminal) -> [UInt8] {
        let keys = held.map(\.code)
        return keys.flatMap { encodeKey($0, action: GHOSTTY_KEY_ACTION_RELEASE, mods: 0, consumed: 0,
                                        unshifted: 0, text: nil, terminal: terminal) }
    }

    private func encodeKey(_ code: UInt16, action: GhosttyKeyAction, mods: GhosttyMods, consumed: GhosttyMods,
                           unshifted: UInt32, text: String?, terminal: VTTerminal,
                           optionKey: Config.OptionKey? = nil) -> [UInt8] {
        guard let encoder, let event else { return [] }
        let release = action == GHOSTTY_KEY_ACTION_RELEASE
        let index = held.firstIndex { $0.code == code }
        var unshifted = unshifted
        var mods = mods
        let policy = optionKey ?? Config.current.optionKey
        var textOption = policy == .text && text != nil && mods & GhosttyMods(GHOSTTY_MODS_ALT) != 0
        if release {
            // Only a press that was encoded can be released.
            guard index != nil else { return [] }
            let key = held.remove(at: index!)
            unshifted = key.unshifted
            textOption = key.textOption
        }
        if textOption { mods &= ~GhosttyMods(GHOSTTY_MODS_ALT) }
        let key = macKeys[code] ?? GHOSTTY_KEY_UNIDENTIFIED
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal.raw)
        var optionAsAlt = policy == .alt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
        ghostty_key_event_set_action(event, action)
        ghostty_key_event_set_key(event, key)
        ghostty_key_event_set_mods(event, mods)
        ghostty_key_event_set_consumed_mods(event, consumed)
        ghostty_key_event_set_composing(event, false)
        ghostty_key_event_set_unshifted_codepoint(event, unshifted)
        // Count UTF-8 bytes rather than strlen: text may hold NUL or exceed
        // the first buffer, and the encoder reports the size it needs.
        var buffer = [CChar](repeating: 0, count: 128)
        var length = 0
        var utf8 = Array((text ?? "").utf8CString.dropLast())
        let result = utf8.withUnsafeMutableBufferPointer { pointer in
            ghostty_key_event_set_utf8(event, text == nil ? nil : pointer.baseAddress, text == nil ? 0 : pointer.count)
            var result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &length)
            if result == GHOSTTY_OUT_OF_SPACE {
                buffer = [CChar](repeating: 0, count: length)
                result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &length)
            }
            return result
        }
        guard result == GHOSTTY_SUCCESS, length > 0 else { return [] }
        if !release, index == nil { held.append((code, unshifted, textOption)) }
        return buffer.prefix(length).map { UInt8(bitPattern: $0) }
    }

    /// Modifier keys by `NSEvent.keyCode`: the flag each controls and its
    /// physical device mask (as in Ghostty's SurfaceView_AppKit). Caps Lock has none.
    private static let modifierKeys: [UInt16: (NSEvent.ModifierFlags, UInt)] = [
        0x38: (.shift, 0x02), 0x3c: (.shift, 0x04),
        0x3b: (.control, 0x01), 0x3e: (.control, 0x2000),
        0x3a: (.option, 0x20), 0x3d: (.option, 0x40),
        0x37: (.command, 0x08), 0x36: (.command, 0x10),
        0x39: (.capsLock, 0),
    ]

    /// Right-side device masks and the Ghostty side bit each one sets.
    private static let sides: [(NSEvent.ModifierFlags, GhosttyMods, UInt)] = [
        (.shift, GhosttyMods(GHOSTTY_MODS_SHIFT_SIDE), 0x04), (.control, GhosttyMods(GHOSTTY_MODS_CTRL_SIDE), 0x2000),
        (.option, GhosttyMods(GHOSTTY_MODS_ALT_SIDE), 0x40), (.command, GhosttyMods(GHOSTTY_MODS_SUPER_SIDE), 0x10),
    ]

    /// Physical keys match Ghostty's defaults across keyboard layouts. Ignore
    /// Caps Lock and Fn when deciding whether a text editing binding matches.
    private static func editingBinding(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        switch (key, modifiers) {
        case (0x7B, .command): [0x01] // beginning of line
        case (0x7C, .command): [0x05] // end of line
        case (0x33, .command): [0x15] // delete to beginning of line
        case (0x7B, .option): [0x1b, 0x62] // previous word
        case (0x7C, .option): [0x1b, 0x66] // next word
        default: nil
        }
    }
}
