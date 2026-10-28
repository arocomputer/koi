import AppKit
import Foundation

/// App settings from Paths.config: one `key = value` per line, with `#` comments.
/// Loading is lenient and records issues; edits validate and throw on failure.
/// The app coordinator assigns current and applies live settings after a reload;
/// session creation settings are consumed by their owners when opening a shell.
struct Config: Equatable {
    /// Tab placement. `side` remains the serialized name for the left rail.
    enum Tabs: String {
        case side, top, right

        var isVertical: Bool { self != .top }
        var isRight: Bool { self == .right }
        var title: String {
            switch self {
            case .side: "Left"
            case .top: "Top"
            case .right: "Right"
            }
        }

        /// Accept the visible Left label without rewriting existing `side` configs.
        static func parse(_ value: String) -> Tabs? {
            value == "left" ? .side : Tabs(rawValue: value)
        }
    }
    /// Animation policy for interface transitions.
    enum Motion: String { case snappy, natural, off }
    /// Automatic preserves native Option text and terminal navigation bindings.
    enum OptionKey: String { case automatic, alt, text }

    static let fontSizeRange: ClosedRange<Double> = 6...72
    static let lineHeightRange: ClosedRange<Double> = 1...3
    // Keep attachments below the wire snapshot budget; larger history needs chunking.
    static let scrollbackMBRange: ClosedRange<Int> = 1...32

    var tabs: Tabs = .side
    var motion: Motion = .snappy
    var reduceTransparency = false
    /// Whether surfaces draw opaque: this preference, or the system's.
    var solidSurfaces: Bool { reduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var lineHeight: Double = 1
    var optionKey: OptionKey = .automatic
    var showPaneHeaders = true
    var compactPanes = false
    var focusFollowsMouse = false
    var fadeInactivePanes = false
    var notifyBlocked = false
    var notifyDone = false
    var notifyError = false
    var quietWhenFocused = true
    var startupCommand = ""
    var scrollbackMB = 32
    var fontSize: CGFloat = 13
    var backgroundOpacity: Double = 0.85
    /// The terminal's font family, or nil for the system monospaced font.
    var fontFamily: String?
    /// The cursor's default shape; nil leaves it to the program (DECSCUSR).
    enum CursorStyle: String { case block, bar, underline, hollow }
    var cursorStyle: CursorStyle?
    /// The cursor's opacity, and its height as a fraction of the text box.
    var cursorOpacity: Double = 1
    var cursorHeight: Double = 1
    /// Human-readable load diagnostics. Invalid values keep that key's default.
    var issues: [String] = []
    /// Shortcuts the config rebinds, over each action's default (see `Action`).
    var binds: [Action: Keybind] = [:]

    /// The shortcut in effect for an action: the config's, or the default.
    func bind(_ action: Action) -> Keybind { binds[action] ?? action.defaultBind }

    /// The settings in effect. Read on the main thread (the render tick and
    /// menu actions), written there too, so the unchecked global is safe.
    nonisolated(unsafe) static var current = Config()
    /// Controls refresh their shortcut accessibility hints after a live reload.
    static let didReload = Notification.Name("KoiConfigReloaded")

    /// A rejected edit is reported before touching disk; filesystem errors propagate.
    enum EditError: LocalizedError {
        case invalidValue(key: String, expected: String)
        case shortcutConflict([String])

        var errorDescription: String? {
            switch self {
            case let .invalidValue(key, expected): "\(key): expected \(expected)."
            case let .shortcutConflict(actions): "Shortcut already used by \(actions.joined(separator: ", "))."
            }
        }
    }

    /// Reads leniently: a missing file is normal; other failures become diagnostics.
    static func load() -> Config {
        do { return parse(try String(contentsOf: Paths.config, encoding: .utf8)) }
        catch {
            var config = Config()
            if !isMissingFile(error) { config.issues = ["Could not read configuration: \(error.localizedDescription)"] }
            return config
        }
    }

    /// Parses without I/O. The last normal-key occurrence wins, even if invalid;
    /// an invalid last value keeps the default rather than reviving an earlier one.
    static func parse(_ text: String) -> Config {
        var config = Config()
        var last: [String: String] = [:]
        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let number = offset + 1
            guard let (key, value) = assignment(line) else {
                config.issues.append("Line \(number): expected key = value.")
                continue
            }
            if key == "keybind" {
                guard let (trigger, name) = assignment(value),
                      let bind = parseTrigger(trigger), let action = Action(rawValue: name) else {
                    config.issues.append("Line \(number): invalid keybind; expected trigger = action.")
                    continue
                }
                config.binds[action] = bind
            } else {
                last[key] = value
                var validated = Config()
                do { try validated.apply(key, value) }
                catch { config.issues.append("Line \(number): \(error.localizedDescription)") }
            }
        }
        for (key, value) in last {
            // Every failure was diagnosed above, including shadowed entries.
            // Starting from defaults makes an invalid final value authoritative.
            try? config.apply(key, value)
        }
        for action in Action.allCases {
            let others = config.conflicts(for: config.bind(action), excluding: action)
            // Report each conflicting pair once, in stable action order.
            for other in others where action.rawValue < other.rawValue {
                config.issues.append("Shortcut \(config.bind(action).configString) is used by \(action.rawValue) and \(other.rawValue).")
            }
        }
        return config
    }

    /// Effective canonical text for a normal setting; empty means no optional
    /// override (or an unknown key). Values round-trip through set and parse.
    func value(for key: String) -> String {
        func number(_ value: Double) -> String {
            guard value.isFinite else { return "" }
            return value.rounded() == value ? String(format: "%.0f", value) : String(value)
        }
        switch key {
        case "tabs": return tabs.rawValue
        case "animation": return motion.rawValue
        case "reduce-transparency": return String(reduceTransparency)
        case "font-size": return number(Double(fontSize))
        case "font-family": return fontFamily ?? ""
        case "line-height": return number(lineHeight)
        case "background-opacity": return number(backgroundOpacity)
        case "cursor-style": return cursorStyle?.rawValue ?? ""
        case "cursor-opacity": return number(cursorOpacity)
        case "cursor-height": return number(cursorHeight)
        case "option-key": return optionKey.rawValue
        case "show-pane-headers": return String(showPaneHeaders)
        case "compact-panes": return String(compactPanes)
        case "focus-follows-mouse": return String(focusFollowsMouse)
        case "fade-inactive-panes": return String(fadeInactivePanes)
        case "notify-blocked": return String(notifyBlocked)
        case "notify-done": return String(notifyDone)
        case "notify-error": return String(notifyError)
        case "quiet-when-focused": return String(quietWhenFocused)
        case "startup-command": return startupCommand
        case "scrollback-mb": return String(scrollbackMB)
        default: return ""
        }
    }

    /// Validates and applies one normal setting; invalid values never mutate it.
    private mutating func apply(_ key: String, _ value: String) throws {
        func invalid(_ expected: String) -> EditError { .invalidValue(key: key, expected: expected) }
        func number(_ range: ClosedRange<Double>) throws -> Double {
            guard let n = Double(value), n.isFinite, range.contains(n) else {
                throw invalid("a finite number from \(range.lowerBound) to \(range.upperBound)")
            }
            return n
        }
        func boolean() throws -> Bool {
            guard let b = Bool(value) else { throw invalid("true or false") }
            return b
        }
        switch key {
        case "tabs":
            guard let v = Tabs.parse(value) else { throw invalid("side, left, top or right") }
            tabs = v
        case "animation":
            guard let v = Motion(rawValue: value) else { throw invalid("snappy, natural or off") }
            motion = v
        case "option-key":
            guard let v = OptionKey(rawValue: value) else { throw invalid("automatic, alt or text") }
            optionKey = v
        case "font-size": fontSize = CGFloat(try number(Self.fontSizeRange))
        case "font-family": fontFamily = value.isEmpty ? nil : value
        case "line-height": lineHeight = try number(Self.lineHeightRange)
        case "background-opacity": backgroundOpacity = try number(0...1)
        case "cursor-style":
            if value.isEmpty { cursorStyle = nil }
            else {
                guard let v = CursorStyle(rawValue: value) else { throw invalid("block, bar, underline or hollow") }
                cursorStyle = v
            }
        case "cursor-opacity": cursorOpacity = try number(0...1)
        case "cursor-height": cursorHeight = try number(0.2...1)
        case "reduce-transparency": reduceTransparency = try boolean()
        case "show-pane-headers": showPaneHeaders = try boolean()
        case "compact-panes": compactPanes = try boolean()
        case "focus-follows-mouse": focusFollowsMouse = try boolean()
        case "fade-inactive-panes": fadeInactivePanes = try boolean()
        case "notify-blocked": notifyBlocked = try boolean()
        case "notify-done": notifyDone = try boolean()
        case "notify-error": notifyError = try boolean()
        case "quiet-when-focused": quietWhenFocused = try boolean()
        case "startup-command": startupCommand = value
        case "scrollback-mb":
            guard let n = Int(value), Self.scrollbackMBRange.contains(n) else {
                throw invalid("an integer from \(Self.scrollbackMBRange.lowerBound) to \(Self.scrollbackMBRange.upperBound) MiB")
            }
            scrollbackMB = n
        default: throw invalid("a recognized configuration key")
        }
    }

    /// Sets a normal key once, removing duplicates and preserving unrelated lines.
    /// No in-memory settings change until the coordinator reloads a successful write.
    static func set(_ key: String, _ value: String) throws {
        guard !value.contains(where: \.isNewline) else {
            throw EditError.invalidValue(key: key, expected: "a single-line value")
        }
        var validated = Config()
        try validated.apply(key, value.trimmingCharacters(in: .whitespaces))
        var lines = try readLines()
        let first = lines.firstIndex { assignment($0)?.key == key }
        lines.removeAll { assignment($0)?.key == key }
        lines.insert("\(key) = \(validated.value(for: key))", at: min(first ?? lines.count, lines.count))
        try writeLines(lines)
    }

    /// Removes every occurrence of a normal key, restoring its built-in default.
    static func reset(key: String) throws {
        var defaults = Config()
        try defaults.apply(key, defaults.value(for: key))
        var lines = try readLines()
        lines.removeAll { assignment($0)?.key == key }
        try writeLines(lines)
    }

    /// All configurable actions using a trigger, optionally excluding its owner.
    /// Defaults participate, so removing an override cannot hide a collision.
    func conflicts(for bind: Keybind, excluding action: Action? = nil) -> [Action] {
        guard !bind.key.isEmpty else { return [] }
        return Action.allCases.filter { $0 != action && self.bind($0) == bind }
    }

    /// Rebinds an action atomically. Conflicts are rejected rather than silently
    /// stealing another action's shortcut; callers can offer a different trigger.
    static func setKeybind(_ action: Action, _ bind: Keybind) throws {
        guard let canonical = parseTrigger(bind.configString), canonical == bind else {
            throw EditError.invalidValue(key: "keybind", expected: "a valid shortcut trigger")
        }
        var lines = try readLines()
        let config = parse(lines.joined(separator: "\n"))
        let conflicts = config.conflicts(for: bind, excluding: action)
        guard conflicts.isEmpty else { throw EditError.shortcutConflict(conflicts.map(\.rawValue)) }
        lines.removeAll { keybindAction($0) == action.rawValue }
        lines.append("keybind = \(bind.configString) = \(action.rawValue)")
        try writeLines(lines)
    }

    /// Drops all overrides for this action; conflicts in the restored default
    /// remain visible through issues and conflicts(for:excluding:).
    static func resetKeybind(_ action: Action) throws {
        var lines = try readLines()
        lines.removeAll { keybindAction($0) == action.rawValue }
        try writeLines(lines)
    }

    /// Splits a non-comment assignment once, retaining '=' inside its value.
    private static func assignment(_ raw: String) -> (key: String, value: String)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    /// Keybind.parse accepts multiple key tokens; require exactly one here so
    /// malformed edits cannot silently become a different shortcut.
    private static func parseTrigger(_ text: String) -> Keybind? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" { return Keybind("", []) }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 9 }) else { return nil }
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let modifiers = ["cmd", "command", "super", "shift", "ctrl", "control", "alt", "opt", "option"]
        guard !parts.contains(""), parts.filter({ !modifiers.contains($0) }).count == 1 else { return nil }
        return Keybind.parse(text)
    }

    /// Extracts the action even when the trigger is invalid, so reset repairs it.
    private static func keybindAction(_ line: String) -> String? {
        guard let (key, value) = assignment(line), key == "keybind" else { return nil }
        return assignment(value)?.value
    }

    /// Only absence means an empty file; permission and decoding errors propagate.
    private static func readLines() throws -> [String] {
        do { return try String(contentsOf: Paths.config, encoding: .utf8).components(separatedBy: "\n") }
        catch {
            if isMissingFile(error) { return [] }
            throw error
        }
    }

    /// Distinguishes an absent file from an unreadable or undecodable config.
    private static func isMissingFile(_ error: any Swift.Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    /// Atomically replaces the file only after both reading and validation succeed.
    private static func writeLines(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: Paths.config, atomically: true, encoding: .utf8)
    }

    /// Best-effort first-launch example; explicit user edits use the throwing APIs.
    static func writeStarterIfMissing() {
        guard !FileManager.default.fileExists(atPath: Paths.config.path) else { return }
        let template = """
        # Koi configuration. Edit, then reload in place with ⌘⇧,.
        # Use one `key = value` per line. Lines beginning with `#` are comments.
        # Inline comments are not supported.

        # font-size = 13
        # font-family = JetBrains Mono
        # background-opacity = 0.85
        # Font size: 6–72 points. Line height: 1–3 times the normal cell height.
        # line-height = 1
        # animation = snappy
        # reduce-transparency = false
        # option-key = automatic
        # show-pane-headers = true
        # compact-panes = false
        # focus-follows-mouse = false
        # fade-inactive-panes = false
        # notify-blocked = false
        # notify-done = false
        # notify-error = false
        # quiet-when-focused = true
        # startup-command =
        # Scrollback history budget per pane: 1–32 MiB.
        # scrollback-mb = 32

        # Cursor. Shape falls back to this until a program sets its own; a
        # program's own choice (e.g. vim's) still wins.
        # Shapes: block, bar, underline, hollow.
        # cursor-style = block
        # Opacity: 0 to 1. Height: 0.2 to 1 of the text box.
        # cursor-opacity = 1.0
        # cursor-height = 1.0

        # Rebind shortcuts: keybind = <trigger> = <action>
        # keybind = cmd+shift+d = new_split_down
        # keybind = cmd+shift+b = toggle_sidebar
        """
        try? FileManager.default.createDirectory(
            at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? template.write(to: Paths.config, atomically: true, encoding: .utf8)
    }
}
