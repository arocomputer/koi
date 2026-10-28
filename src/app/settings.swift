import AppKit
import Observation
import SwiftUI

/// Compact glass Settings: dismisses on blur and never zooms or enters full screen.
final class SettingsWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        minSize = frame.size
        maxSize = frame.size
        collectionBehavior = [.fullScreenNone]
        isReleasedWhenClosed = false
    }

    /// Let a sheet or modal operation acquire focus before deciding to dismiss.
    override func resignKey() {
        super.resignKey()
        Task { @MainActor [weak self] in
            guard let self, !isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil else { return }
            close()
        }
    }

    /// Consume window shortcuts here so closing Settings never reaches a terminal.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        if flags == [.command, .control], event.charactersIgnoringModifiers?.lowercased() == "f" { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func zoom(_ sender: Any?) {}
    override func performZoom(_ sender: Any?) {}
    override func toggleFullScreen(_ sender: Any?) {}
}

/// Horizontal Settings categories. Keep `keybindings` stable for callers.
enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case terminal = "Terminal"
    case keybindings = "Shortcuts"
    case machines = "Machines & Server"
    case activity = "Activity"
    case advanced = "Advanced"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .appearance: "paintpalette"
        case .terminal: "terminal"
        case .keybindings: "keyboard"
        case .machines: "network"
        case .activity: "bell"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Search metadata and control descriptions for this window, not a config schema.
struct SettingsItem: Identifiable {
    struct Choice: Identifiable {
        let value: String
        let title: String
        var id: String { value }
        init(_ value: String, _ title: String) { self.value = value; self.title = title }
    }
    enum Control {
        case toggle, text, font
        case number(ClosedRange<Double>, step: Double)
        case choice([Choice])
    }
    let id: String
    let tab: SettingsTab
    let group: String
    let title: String
    let detail: String
    let control: Control

    /// Every search word may match the category, group, label, description or key.
    func matches(_ query: String) -> Bool {
        SettingsSearch.matches(query, in: [id, tab.rawValue, group, title, detail])
    }

    static let all: [SettingsItem] = [
        .init(id: "background-opacity", tab: .appearance, group: "Glass & motion", title: "Background opacity", detail: "From fully transparent to opaque.", control: .number(0...1, step: 0.01)),
        .init(id: "reduce-transparency", tab: .appearance, group: "Glass & motion", title: "Reduce transparency", detail: "Use more solid window surfaces.", control: .toggle),
        .init(id: "animation", tab: .appearance, group: "Glass & motion", title: "Animation", detail: "Choose snappy, natural, or no interface motion.", control: .choice([.init("snappy", "Snappy"), .init("natural", "Natural"), .init("off", "Off")])),
        .init(id: "tabs", tab: .appearance, group: "Tabs", title: "Tab placement", detail: "Place terminal tabs on the left, top or right.", control: .choice([.init("side", "Left"), .init("top", "Top"), .init("right", "Right")])),
        .init(id: "show-pane-headers", tab: .appearance, group: "Tabs & panes", title: "Show pane headers", detail: "Display the title above each terminal pane.", control: .toggle),
        .init(id: "compact-panes", tab: .appearance, group: "Tabs & panes", title: "Compact panes", detail: "Use tighter spacing between terminal panes.", control: .toggle),
        .init(id: "fade-inactive-panes", tab: .appearance, group: "Tabs & panes", title: "Fade inactive panes", detail: "Dim panes that do not have focus.", control: .toggle),
        .init(id: "font-family", tab: .terminal, group: "Text", title: "Font family", detail: "Choose an installed font or enter a family name. Empty uses system monospace.", control: .font),
        .init(id: "font-size", tab: .terminal, group: "Text", title: "Font size", detail: "Terminal text size in points, from 6 to 72.", control: .number(6...72, step: 1)),
        .init(id: "line-height", tab: .terminal, group: "Text", title: "Line height", detail: "Text line spacing multiplier, from 1 to 3.", control: .number(1...3, step: 0.05)),
        .init(id: "cursor-style", tab: .terminal, group: "Cursor", title: "Cursor style", detail: "Programs can override the default cursor shape.", control: .choice([.init("", "Program default"), .init("block", "Block"), .init("bar", "Bar"), .init("underline", "Underline"), .init("hollow", "Hollow")])),
        .init(id: "cursor-opacity", tab: .terminal, group: "Cursor", title: "Cursor opacity", detail: "From invisible to fully opaque.", control: .number(0...1, step: 0.01)),
        .init(id: "cursor-height", tab: .terminal, group: "Cursor", title: "Cursor height", detail: "Fraction of the text box occupied by the cursor.", control: .number(0.2...1, step: 0.05)),
        .init(id: "option-key", tab: .terminal, group: "Input & sessions", title: "Option key", detail: "Automatic behavior, send Alt, or enter text and special characters.", control: .choice([.init("automatic", "Automatic"), .init("alt", "Alt"), .init("text", "Text")])),
        .init(id: "focus-follows-mouse", tab: .terminal, group: "Input & sessions", title: "Focus follows mouse", detail: "Focus the pane under the pointer.", control: .toggle),
        .init(id: "startup-command", tab: .terminal, group: "Input & sessions", title: "Startup command", detail: "Command for new sessions. Empty uses your default shell; existing sessions keep running.", control: .text),
        .init(id: "scrollback-mb", tab: .terminal, group: "Input & sessions", title: "Scrollback limit", detail: "History budget per pane in MiB, up to 32 for reliable reattachment. Applies with a compatible server.", control: .number(1...32, step: 1)),
        .init(id: "notify-blocked", tab: .activity, group: "Notifications", title: "Waiting for input", detail: "Notify when a task is blocked and needs attention.", control: .toggle),
        .init(id: "notify-done", tab: .activity, group: "Notifications", title: "Task completed", detail: "Notify when a task finishes successfully.", control: .toggle),
        .init(id: "notify-error", tab: .activity, group: "Notifications", title: "Task failed", detail: "Notify when a task reports an error.", control: .toggle),
        .init(id: "quiet-when-focused", tab: .activity, group: "Notifications", title: "Quiet when focused", detail: "Suppress notifications while Koi has focus.", control: .toggle),
    ]
}

/// Shared word matching for controls, shortcut names and integration sections.
enum SettingsSearch {
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let text = fields.joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func group(_ action: Action) -> String {
        switch action {
        case .newWindow, .fullScreen: "Window"
        case .copy, .selectAll, .find: "Editing"
        case .clearScrollback, .resetTerminal, .previousPrompt, .nextPrompt, .insertPath, .goDirectory: "Terminal"
        case .saveProject, .openProject: "Projects"
        case .showActivity: "Activity"
        case .checkUpdates, .diagnostics: "Settings"
        case .commandPalette: "Palette"
        case .newTab, .closeTab, .nextTab, .previousTab: "Tabs"
        case .closePane, .newSplit, .newSplitDown, .toggleZoom, .nextPane, .previousPane,
             .focusSplitLeft, .focusSplitRight, .focusSplitUp, .focusSplitDown: "Panes"
        case .toggleSidebar: "Appearance"
        case .increaseFontSize, .decreaseFontSize, .resetFontSize: "Terminal"
        case .paste: "Editing"
        case .reloadConfig, .openConfig: "Settings"
        }
    }
}

/// Bounds shared by category strip buttons and mouse dragging; never wraps.
struct SettingsScrollBounds: Equatable {
    var offset: CGFloat = 0
    var width: CGFloat = 0
    var contentWidth: CGFloat = 0
    var maximum: CGFloat { max(0, contentWidth - width) }
    var canGoLeft: Bool { clamped(offset) > 0.5 }
    var canGoRight: Bool { clamped(offset) < maximum - 0.5 }
    func clamped(_ proposed: CGFloat) -> CGFloat { min(max(0, proposed), maximum) }
    func page(_ direction: CGFloat) -> CGFloat { clamped(clamped(offset) + direction * max(80, width * 0.75)) }
}

/// Compact glass Settings. Persistence callbacks must throw on failure and
/// reload Config.current / post Config.didReload after successful writes.
/// `machines` supplies the coordinator's live machine management and server status.
struct SettingsView: View {
    let apply: (_ key: String, _ value: String) throws -> Void
    /// An empty-key binding means Unassigned, distinct from restoring a default.
    let rebind: (_ action: Action, _ bind: Keybind) throws -> Void
    let reset: (_ key: String) throws -> Void
    let resetKeybind: (_ action: Action) throws -> Void
    let openConfigFile: () -> Void
    let machines: () -> AnyView
    let version: String
    let openLogs: () throws -> Void
    let copyDiagnostics: () throws -> Void
    let checkForUpdates: () throws -> Void
    let installCLI: () throws -> Void
    var activityContent: () -> AnyView = { AnyView(EmptyView()) }
    var advancedContent: () -> AnyView = { AnyView(EmptyView()) }
    var exportDiagnostics: () throws -> Void = {}

    @State private var tab: SettingsTab = .appearance
    @State private var query = ""
    @State private var config = Config.current
    @State private var drafts: [String: String] = [:]
    @State private var error: String?
    @State private var position = ScrollPosition()
    @State private var bounds = SettingsScrollBounds()
    @State private var dragOrigin: CGFloat?
    @GestureState private var dragging = false

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var matchingActions: [Action] {
        Action.allCases.filter { action in
            SettingsSearch.matches(query, in: ["Shortcuts", SettingsSearch.group(action), action.title,
                                               action.rawValue, config.bind(action).symbols, config.bind(action).configString])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar.padding(.horizontal, 10).frame(height: AppDelegate.topRow)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all settings", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Search all settings")
                if !query.isEmpty { Button("Clear", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly).buttonStyle(.plain) }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            .padding(.horizontal, 18).padding(.bottom, 10)
            if let error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { self.error = nil }
                }
                .font(.callout).foregroundStyle(.red).padding(12)
                .background(.red.opacity(0.08), in: .rect(cornerRadius: 8))
                .padding(.horizontal, 18).padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if searching { searchResults } else { category(tab) }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(config.solidSurfaces
                        ? AnyShapeStyle(Theme.current.backgroundColor) : AnyShapeStyle(.ultraThinMaterial))
            .background(Theme.current.backgroundColor.opacity(0.55))
            .clipShape(.rect(cornerRadius: AppDelegate.paneCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppDelegate.paneCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .padding([.horizontal, .bottom], AppDelegate.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in config = Config.current }
    }

    /// Native two-finger scrolling plus bounded mouse dragging. No key handlers.
    private var tabBar: some View {
        HStack(spacing: 4) {
            scrollButton("chevron.left", title: "Scroll categories left", enabled: bounds.canGoLeft, direction: -1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(SettingsTab.allCases) { item in
                            Button {
                                tab = item; query = ""
                                proxy.scrollTo(item.id, anchor: .center)
                            } label: {
                                Label(item.rawValue, systemImage: item.icon)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .modifier(SelectionSurface(selected: tab == item && !searching))
                                    .foregroundStyle(tab == item && !searching ? .primary : .secondary)
                            }
                            .buttonStyle(.plain).id(item.id)
                            .accessibilityAddTraits(tab == item && !searching ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden).scrollPosition($position)
                .onScrollGeometryChange(for: SettingsScrollBounds.self, of: {
                    SettingsScrollBounds(offset: $0.contentOffset.x, width: $0.containerSize.width, contentWidth: $0.contentSize.width)
                }) { _, new in bounds = new }
                .highPriorityGesture(DragGesture(minimumDistance: 6)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = bounds.offset }
                        position.scrollTo(x: bounds.clamped((dragOrigin ?? 0) - value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil })
                .onChange(of: dragging) { _, active in if !active { dragOrigin = nil } }
            }
            scrollButton("chevron.right", title: "Scroll categories right", enabled: bounds.canGoRight, direction: 1)
        }
    }

    private func scrollButton(_ icon: String, title: String, enabled: Bool, direction: CGFloat) -> some View {
        Button { position.scrollTo(x: bounds.page(direction)) } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 28)
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 0.8 : 0.2)
        .accessibilityLabel(title).help(title)
    }

    @ViewBuilder private var searchResults: some View {
        let categories = SettingsTab.allCases.filter { hasResults($0) }
        if categories.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ForEach(categories) { category in
                Text(category.rawValue).font(.title3.weight(.semibold))
                self.category(category)
            }
        }
    }

    private func hasResults(_ category: SettingsTab) -> Bool {
        switch category {
        case .keybindings: !matchingActions.isEmpty
        case .machines: SettingsSearch.matches(query, in: [category.rawValue, "connections SSH remote local status version server install logs"])
        case .advanced: SettingsSearch.matches(query, in: [category.rawValue, "configuration config file issues diagnostics updates release feed version logs CLI command line install integrations Codex Claude shell Zsh prompts"] + config.issues)
        default: SettingsItem.all.contains { $0.tab == category && $0.matches(query) }
        }
    }

    @ViewBuilder private func category(_ category: SettingsTab) -> some View {
        switch category {
        case .keybindings: shortcuts
        case .machines: machines()
        case .advanced: advanced
        default:
            let items = SettingsItem.all.filter { $0.tab == category && (!searching || $0.matches(query)) }
            let groups = items.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 14) {
                    Text(group).font(.headline).foregroundStyle(.secondary)
                    ForEach(items.filter { $0.group == group }) { item in settingRow(item) }
                }
            }
            if category == .terminal && (!searching || items.contains { ["font-family", "font-size", "line-height", "cursor-style", "cursor-height", "cursor-opacity"].contains($0.id) }) {
                terminalPreview
            }
            if category == .activity { activityContent() }
        }
    }

    private func settingRow(_ item: SettingsItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: .medium))
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { resetValue(item.id) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Reset \(item.title)").accessibilityLabel("Reset \(item.title)")
            }
            control(item).accessibilityLabel(item.title)
            Divider().opacity(0.35)
        }
    }

    @ViewBuilder private func control(_ item: SettingsItem) -> some View {
        switch item.control {
        case .toggle:
            Toggle(item.title, isOn: Binding(get: { config.value(for: item.id) == "true" }, set: { save(item.id, $0 ? "true" : "false") }))
                .toggleStyle(.switch).labelsHidden()
        case .choice(let choices):
            SettingsChoicePicker(id: item.id, value: config.value(for: item.id), choices: choices) { value in
                if value.isEmpty { resetValue(item.id) } else { save(item.id, value) }
            }
        case .number(let range, let step):
            HStack(spacing: 12) {
                Slider(value: Binding(get: { range.clamping(Double(value(item.id)) ?? range.lowerBound) }, set: { drafts[item.id] = String(format: "%.2f", $0) }), in: range, step: step) { editing in
                    if !editing { commit(item) }
                }
                .accessibilityLabel(item.title)
                draftField(item).frame(maxWidth: 260)
            }
        case .text: draftField(item)
        case .font:
            VStack(alignment: .leading, spacing: 8) {
                SettingsFontPicker { family in save(item.id, family) }
                draftField(item)
            }

        }
    }

    private func draftField(_ item: SettingsItem) -> some View {
        HStack(spacing: 8) {
            TextField(item.id == "font-family" ? "System monospace" : item.title, text: Binding(get: { value(item.id) }, set: { drafts[item.id] = $0 }))
                .textFieldStyle(.roundedBorder).onSubmit { commit(item) }
                .accessibilityLabel(item.title)
            if drafts[item.id] != nil {
                Button("Save") { commit(item) }.buttonStyle(.bordered)
                Button("Revert") { drafts.removeValue(forKey: item.id) }.buttonStyle(.plain)
            }
        }
    }

    /// Drafts are intentionally independent of focus and config reloads.
    private func value(_ key: String) -> String { drafts[key] ?? config.value(for: key) }

    private func commit(_ item: SettingsItem) {
        let text = value(item.id)
        switch item.control {
        case .number(let range, let step):
            guard let number = Double(text), number.isFinite, range.contains(number), step != 1 || number.rounded() == number else {
                error = "\(item.title) must be \(step == 1 ? "a whole number" : "a number") from \(range.lowerBound) to \(range.upperBound)."; return
            }
            save(item.id, step == 1 ? String(Int(number)) : String(number))
        default: save(item.id, text)
        }
    }

    private func save(_ key: String, _ value: String) {
        perform {
            try apply(key, value)
            drafts.removeValue(forKey: key)
        }
    }

    private func resetValue(_ key: String) {
        perform {
            try reset(key)
            drafts.removeValue(forKey: key)
        }
    }

    /// Failures leave drafts intact; successful mutations refresh canonical values.
    private func perform(_ operation: () throws -> Void) {
        defer { config = Config.current }
        do { try operation(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    /// Fixed terminal colors keep the preview consistent with actual rendering.
    private func color(_ key: String) -> Color {
        let rgb = key == "background" ? Theme.current.background : key == "cursor" ? Theme.current.cursor : Theme.current.foreground
        return Color(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    /// Uses the selected installed font and draft metrics before they are saved.
    private var terminalPreview: some View {
        let size = min(max(Double(value("font-size")) ?? 13, 6), 72)
        let font = SettingsFontPicker.font(value("font-family"), size: size)
        let height = min(max(Double(value("line-height")) ?? 1, Config.lineHeightRange.lowerBound), Config.lineHeightRange.upperBound)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Terminal preview").font(.headline).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("~/projects/koi  main").frame(height: font.ascender - font.descender, alignment: .center)
                    HStack(spacing: 0) {
                        Text("❯ echo Hello, world! ")
                        cursorPreview(width: max(1, font.maximumAdvancement.width), height: font.ascender - font.descender)
                    }
                    .frame(height: (font.ascender - font.descender) * height)
                    Text("Hello, world!  0123456789").frame(height: (font.ascender - font.descender) * height)
                }
                .font(Font(font)).foregroundStyle(color("foreground")).padding(16)
            }
            .background(color("background").opacity(min(max(Double(value("background-opacity")) ?? config.backgroundOpacity, 0), 1)), in: .rect(cornerRadius: 10))
        }
    }

    private func cursorPreview(width: CGFloat, height: CGFloat) -> some View {
        let style = value("cursor-style")
        let fraction = min(max(Double(value("cursor-height")) ?? 1, 0.2), 1)
        return ZStack(alignment: .bottomLeading) {
            if style == "hollow" { Rectangle().strokeBorder(color("cursor"), lineWidth: 1) }
            else { Rectangle().fill(color("cursor")) }
        }
        .frame(width: style == "bar" ? 2 : width, height: style == "underline" ? 2 : height * fraction)
        .opacity(min(max(Double(value("cursor-opacity")) ?? 1, 0), 1))
        .frame(width: width, height: height, alignment: .bottomLeading)
    }

    private var shortcuts: some View {
        let actions = searching ? matchingActions : Action.allCases
        let groups = ["Palette", "Window", "Tabs", "Panes", "Projects", "Appearance", "Editing", "Terminal", "Activity", "Settings"]
        return VStack(alignment: .leading, spacing: 18) {
            Text("Click a shortcut to record. Clear removes its binding; Reset restores its default.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(groups.filter { group in actions.contains { SettingsSearch.group($0) == group } }, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group).font(.headline).foregroundStyle(.secondary)
                    ForEach(actions.filter { SettingsSearch.group($0) == group }, id: \.self) { action in shortcutRow(action) }
                }
            }
        }
    }

    private func shortcutRow(_ action: Action) -> some View {
        let bind = config.bind(action)
        let collisions = config.conflicts(for: bind, excluding: action)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                KeyRecorder(title: action.title, bind: bind, action: action, config: config) { candidate in
                    try rebind(action, candidate)
                    config = Config.current
                }
                Button("Clear") { perform { try rebind(action, Keybind("", [])) } }
                    .buttonStyle(.plain).disabled(bind.key.isEmpty)
                Button { perform { try resetKeybind(action) } } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("Reset \(action.title)").accessibilityLabel("Reset \(action.title)")
            }
            if !collisions.isEmpty {
                Label("Also assigned to \(collisions.map(\.title).joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider().opacity(0.35)
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Koi \(version)").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Configuration").font(.headline).foregroundStyle(.secondary)
                if config.issues.isEmpty {
                    Label("No configuration issues", systemImage: "checkmark.circle").font(.callout)
                } else {
                    ForEach(Array(config.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                Button("Open config file…", action: openConfigFile)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { supportButtons }
                VStack(alignment: .leading, spacing: 12) { supportButtons }
            }
            advancedContent()
        }.buttonStyle(.bordered)
    }

    @ViewBuilder private var supportButtons: some View {
        Button("Open logs…") { perform(openLogs) }
        Button("Copy diagnostics") { perform(copyDiagnostics) }
        Button("Export diagnostics…") { perform(exportDiagnostics) }
        Button("Check for updates…") { perform(checkForUpdates) }
        Button("Install CLI…") { perform(installCLI) }
    }
}

private extension ClosedRange where Bound == Double {
    func clamping(_ value: Double) -> Double { value.isFinite ? Swift.min(Swift.max(value, lowerBound), upperBound) : lowerBound }
}

/// A custom, nonanimated popup used for finite config choices.
private struct SettingsChoicePicker: View {
    let id: String
    let value: String
    let choices: [SettingsItem.Choice]
    let select: (String) -> Void
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack {
                Text(choices.first { $0.value == value }?.title ?? (value.isEmpty ? "Default" : value))
                Spacer()
                Image(systemName: "chevron.down").font(.caption)
            }
            .padding(8).frame(maxWidth: 280).background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .koiPopup(isPresented: $showing, id: "settings-\(id)") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(choices) { choice in
                    Button { showing = false; select(choice.value) } label: {
                        HStack {
                            Text(choice.title)
                            Spacer()
                            if value == choice.value { Image(systemName: "checkmark") }
                        }.padding(8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(6).frame(width: 240)
        }
    }
}

/// Lists installed font families with an actual font preview in the shared popup.
private struct SettingsFontPicker: View {
    let select: (String) -> Void
    @State private var showing = false
    @State private var query = ""
    @State private var families = NSFontManager.shared.availableFontFamilies.sorted()

    static func font(_ family: String, size: Double) -> NSFont {
        guard !family.isEmpty else { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: family, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var body: some View {
        Button("Choose installed font…") { showing.toggle() }
            .buttonStyle(.bordered)
            .koiPopup(isPresented: $showing, id: "settings-font") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search fonts", text: $query).textFieldStyle(.roundedBorder)
                    Button("System monospace") { showing = false; select("") }.buttonStyle(.plain)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(families.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { family in
                                Button { showing = false; select(family) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(family).font(.caption).foregroundStyle(.secondary)
                                        Text("Aa Bb 0123 → ❯").font(Font(Self.font(family, size: 16)))
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 250)
                }.padding(12).frame(width: 300)
            }
    }
}

/// One recording session owns its monitors, scoped to the initiating window.
/// Weak captures and deinit cleanup prevent orphaned monitors consuming keys.
@MainActor @Observable private final class SettingsRecordingSession {
    var active = false
    var held: NSEvent.ModifierFlags = []
    var feedback: String?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    isolated deinit {
        monitors.forEach(NSEvent.removeMonitor)
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func start(record: @escaping (Keybind) throws -> Void) {
        guard !active, let window = NSApp.keyWindow else { return }
        active = true; held = []; feedback = nil
        let keyDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, self.active, let window, event.window === window else { return event }
            if event.keyCode == 53 { self.stop(); return nil }
            guard let bind = Keybind.from(event) else {
                self.feedback = "Include Command, Control, Option or Shift."; return nil
            }
            do { try record(bind); self.stop() }
            catch { self.feedback = error.localizedDescription }
            return nil
        }
        let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak window] event in
            guard let window, event.window === window else { return event }
            self?.held = event.modifierFlags
            return event
        }
        monitors = [keyDown, flags].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        active = false; held = []
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    }
}

/// Controlled shortcut display: parent reloads immediately update the label.
/// Only a recording session captures keys. Conflicting candidates stay unsaved.
struct KeyRecorder: View {
    let title: String
    let bind: Keybind
    var action: Action? = nil
    /// The bindings a candidate must not collide with, defaults included.
    var config = Config()
    let onRecord: (Keybind) throws -> Void
    @State private var session = SettingsRecordingSession()

    private struct Conflict: LocalizedError {
        let actions: [Action]
        var errorDescription: String? { "Already used by \(actions.map(\.title).joined(separator: ", ")). Choose another shortcut." }
    }

    var body: some View {
        Button(action: start) {
            Text(bind.key.isEmpty ? "Unassigned" : bind.symbols)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(session.active ? Color.accentColor : .secondary)
                .frame(minWidth: 56).padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.primary.opacity(session.active ? 0.14 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel("Record shortcut for \(title)")
        .onDisappear { session.stop() }
        .koiPopup(isPresented: Binding(get: { session.active }, set: { if $0 { start() } else { session.stop() } }), id: "shortcut") { recordingCard }
        .onChange(of: bind) { _, _ in session.stop() }
        .onChange(of: config) { _, _ in session.stop() }
        .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in session.stop() }
    }

    private func start() {
        // Capture only recording inputs, never the view that owns the session.
        let action = self.action
        let config = self.config
        let record = self.onRecord
        session.start { candidate in
            let conflicts = config.conflicts(for: candidate, excluding: action)
            guard conflicts.isEmpty else { throw Conflict(actions: conflicts) }
            try record(candidate)
        }
    }

    private var recordingCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(keycaps, id: \.self) { cap in
                    Text(cap).font(.system(size: 18, weight: .medium)).frame(minWidth: 34, minHeight: 34)
                        .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 9, style: .continuous))
                }
                if keycaps.isEmpty { Text("Press keys…").foregroundStyle(.secondary) }
            }.frame(minHeight: 45)
            if let feedback = session.feedback { Text(feedback).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel · Esc") { session.stop() }.buttonStyle(.plain).font(.caption)
            }
        }.padding(12).frame(width: 300)
    }

    private var keycaps: [String] {
        var caps: [String] = []
        if session.held.contains(.control) { caps.append("⌃") }
        if session.held.contains(.option) { caps.append("⌥") }
        if session.held.contains(.shift) { caps.append("⇧") }
        if session.held.contains(.command) { caps.append("⌘") }
        return caps
    }
}
