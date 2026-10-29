import AppKit
import SwiftUI

/// A searchable command or destination. Operations execute only after the
/// popup closes, so terminal actions receive keyboard focus correctly.
@MainActor struct PaletteItem: Identifiable {
    enum Kind { case command, tab, pane, machine }
    enum Category: String, CaseIterable {
        case tabs = "Tabs", panes = "Panes", terminal = "Terminal", machines = "Machines"
        case appearance = "Appearance", settings = "Settings", window = "Window"
    }
    enum Operation {
        case perform(@MainActor () -> Void)
        case prompt(@MainActor () -> PalettePrompt)
        case choices(@MainActor () -> PaletteChoices)
    }

    var id: String
    var title: String
    var detail: String
    var symbol: String
    var keywords: [String] = []
    var shortcut: String = ""
    var kind: Kind = .command
    var category: Category = .tabs
    var destructive = false
    var enabled = true
    var style: ProgramStyle?
    var status: Wire.Status?
    var operation: Operation

    /// Categories belong in section headings; keep only useful row metadata.
    var subtitle: String? {
        guard !detail.isEmpty else { return nil }
        return kind == .command && enabled && detail == category.rawValue ? nil : detail
    }
    var rowHeight: CGFloat { subtitle == nil ? 36 : 44 }
}

/// A text-entry step. Validation runs before dismissal; submission runs after
/// it. Suggestions offer SSH aliases without reading configuration per key.
@MainActor struct PalettePrompt {
    var title: String
    var placeholder: String
    var initial = ""
    var button = "Save"
    var suggestions: [String] = []
    var validate: (String) -> String? = { $0.isEmpty ? "Enter a value." : nil }
    var submit: (String) -> Void
}

/// A searchable destination list, such as open work or known machines.
@MainActor struct PaletteChoices {
    var title: String
    var items: () -> [PaletteItem]
    var placeholder = "Search commands…"
}

/// A heading and its rows share one ordered keyboard-navigation sequence.
@MainActor struct PaletteSection: Identifiable {
    var id: String
    var title: String?
    var items: [PaletteItem]
}

/// Commands appear directly in their feature groups. Open work has a focused
/// browser, while search ranks recent choices without duplicating root rows.
@MainActor enum PalettePresentation {
    static func home(items: @escaping @MainActor () -> [PaletteItem]) -> [PaletteSection] {
        let work = PaletteItem(id: "browse_work", title: "Open Tabs & Panes…", detail: "", symbol: "rectangle.stack",
                               operation: .choices {
            PaletteChoices(title: "Open Tabs & Panes", items: { items().filter { $0.kind == .tab || $0.kind == .pane } },
                           placeholder: "Search tabs, programs, directories…")
        })
        return commands(items() + [work])
    }

    /// Browse in a fixed category order, with closing actions at the end.
    /// Unavailable commands stay discoverable through an explicit search.
    static func commands(_ items: [PaletteItem]) -> [PaletteSection] {
        let available = items.filter { $0.enabled && $0.kind == .command }
        var sections = PaletteItem.Category.allCases.compactMap { category -> PaletteSection? in
            let rows = available.filter { $0.category == category && !$0.destructive }
            return rows.isEmpty ? nil : .init(id: category.rawValue, title: category.rawValue, items: rows)
        }
        let closing = available.filter(\.destructive)
        if !closing.isEmpty { sections.append(.init(id: "closing", title: "Close Actions", items: closing)) }
        return sections
    }
}

/// Local matching over names and metadata. Every query word must match;
/// exact/prefix matches outrank substrings and abbreviated word matches.
@MainActor enum PaletteSearch {
    static func results(_ items: [PaletteItem], query: String, recent: [String]) -> [PaletteItem] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let ranks = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return items.enumerated().compactMap { index, item -> (PaletteItem, Int, Int)? in
            if words.isEmpty {
                let rank = ranks[item.id] ?? (item.kind == .command ? 200 : 100)
                return (item, rank + (item.destructive ? 1000 : 0) + (item.enabled ? 0 : 2000), index)
            }
            if let status = item.status, words.contains(where: {
                if let requested = requestedStatus($0) { return requested != status }
                return false
            }) { return nil }
            let fields = [normalized(item.title), normalized(item.detail)] + item.keywords.map(normalized)
            var total = 0
            for word in words {
                guard let score = fields.compactMap({ match(word, in: $0) }).min() else { return nil }
                total += score
            }
            return (item, total * 100 + (ranks[item.id] ?? 20), index)
        }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    /// Explicit activity words filter reported status, even if a task's title
    /// mentions another activity (for example, "fix waiting queue").
    private static func requestedStatus(_ word: String) -> Wire.Status? {
        switch word {
        case "idle", "ready": .idle
        case "working", "running", "busy": .working
        case "blocked", "waiting": .blocked
        case "done", "finished", "complete", "completed": .done
        case "error", "failed", "failure": .error
        default: nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func match(_ word: String, in field: String) -> Int? {
        if field == word { return 0 }
        if field.hasPrefix(word) { return 1 }
        if field.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) { return 2 }
        if field.contains(word) { return 3 }
        guard word.count >= 2 else { return nil }
        for candidate in field.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var next = word.startIndex
            for character in candidate where next < word.endIndex {
                if word[next] == character { next = word.index(after: next) }
            }
            if next == word.endIndex { return 6 }
        }
        return nil
    }

    /// Friendly status words also serve as search aliases for agent activity.
    static func statusWords(_ status: Wire.Status) -> [String] {
        switch status {
        case .idle: ["idle", "ready"]
        case .working: ["working", "running", "busy"]
        case .blocked: ["blocked", "waiting", "needs input", "attention"]
        case .done: ["done", "finished", "complete", "completed"]
        case .error: ["error", "failed", "failure"]
        }
    }

    /// Builds one directly focusable result per pane. Split tabs also get a
    /// tab result, while program/status searches point at individual panes.
    /// Walks the tree once, preserving display order and group search metadata.
    static func workItems(in workspace: Workspace, navigate: @escaping @MainActor (String, String?) -> Void) -> [PaletteItem] {
        var items: [PaletteItem] = []
        /// Adds destinations using the group context already known by the traversal.
        @MainActor func appendWork(for tab: Wire.TabInfo, groupName: String) {
            let tabID = tab.id
            let paneCount = tab.panes.count
            if paneCount > 1 {
                let title = tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Tab with \(paneCount) panes"
                items.append(.init(id: "tab:\(workspace.endpoint.key):\(tabID)", title: title,
                                   detail: "\(workspace.endpoint.title) · \(paneCount) panes", symbol: "rectangle.stack",
                                   keywords: [title, groupName, workspace.endpoint.title, "tab"], kind: .tab,
                                   operation: .perform { navigate(tabID, nil) }))
            }
            for pane in tab.panes {
                let paneID = pane.id
                items.append(paneItem(pane, tabName: tab.name, group: groupName, endpoint: workspace.endpoint,
                                      isSplit: paneCount > 1, navigate: { navigate(tabID, paneID) }))
            }
        }
        for item in workspace.state.items {
            switch item {
            case .tab(let tab): appendWork(for: tab, groupName: "")
            case .group(let group):
                for tab in group.tabs { appendWork(for: tab, groupName: group.name) }
            }
        }
        return items
    }

    /// Keeps full metadata searchable even when a row truncates its subtitle.
    static func paneItem(_ pane: Wire.PaneInfo, tabName: String?, group: String, endpoint: Endpoint,
                         isSplit: Bool, navigate: @escaping @MainActor () -> Void) -> PaletteItem {
        let style = Programs.style(for: pane)
        let custom = tabName.flatMap { $0.isEmpty ? nil : $0 }
        let title = (!isSplit ? custom : nil) ?? TabLabel.make(pane, style).title
        let home = pane.home ?? (endpoint == .local ? NSHomeDirectory() : "")
        let directory = home.isEmpty ? pane.cwd : Paths.tilde(pane.cwd, home: home)
        let parts = [style.name, isSplit ? custom ?? "" : "", directory, endpoint.title].filter { !$0.isEmpty }
        return .init(id: "pane:\(endpoint.key):\(pane.id)", title: title, detail: parts.joined(separator: " · "),
                     symbol: "terminal", keywords: [pane.program, pane.title, pane.shell, style.name, pane.cwd, directory,
                     custom ?? "", group, endpoint.title, endpoint == .local ? "local this mac" : "remote ssh",
                     isSplit ? "pane" : "tab"] + statusWords(pane.status),
                     kind: isSplit ? .pane : .tab, style: style, status: pane.status, operation: .perform(navigate))
    }
}

/// Search, result navigation, and small input/choice steps inside the shared
/// glass popup. Recents store stable IDs, never search text or terminal output.
struct CommandPalette: View {
    let items: @MainActor () -> [PaletteItem]
    let maxHeight: CGFloat
    @Environment(\.dismissPopup) private var dismiss
    @State private var query: String
    @State private var selectedID: String?
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "paletteRecents") ?? []
    @State private var choices: PaletteChoices?
    @State private var prompt: PalettePrompt?
    @State private var value = ""
    @State private var validation: String?
    @State private var navigation: [Location] = []
    @State private var pendingID: String?
    /// Back restores the previous scope, query and keyboard selection together.
    private struct Location {
        var choices: PaletteChoices?
        var query: String
        var selectedID: String?
    }

    /// A direct choice scope still has a Back path to the palette home.
    init(query: String = "", choices: PaletteChoices? = nil, prompt: PalettePrompt? = nil, maxHeight: CGFloat, items: @escaping @MainActor () -> [PaletteItem]) {
        _query = State(initialValue: query)
        _choices = State(initialValue: choices)
        _prompt = State(initialValue: prompt)
        _value = State(initialValue: prompt?.initial ?? "")
        _navigation = State(initialValue: choices == nil && prompt == nil ? [] : [Location(choices: nil, query: "", selectedID: nil)])
        self.maxHeight = maxHeight
        self.items = items
    }

    private var sections: [PaletteSection] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if choices == nil { return PalettePresentation.home(items: items) }
        }
        return [.init(id: "results", title: nil, items:
            PaletteSearch.results(choices?.items() ?? items(), query: query, recent: choices == nil ? recent : []))]
    }
    private var results: [PaletteItem] { sections.flatMap(\.items) }

    private var selection: String? {
        results.first { $0.id == selectedID && $0.enabled }?.id ?? results.first { $0.enabled }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if prompt != nil || choices != nil { stepHeader }
            if let prompt {
                input(prompt)
            } else {
                search
                resultList
            }
            if prompt == nil {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Navigate")
                        PaletteKeycap(symbols: "↑↓")
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text("Select")
                        PaletteKeycap(symbols: "↩")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 15)
                .padding(.bottom, 10)
                .padding(.top, 3)
            }
        }
        .frame(width: 400)
        .accessibilityLabel("Command Palette")
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            PaletteField(text: Binding(get: { query }, set: { query = $0; selectedID = nil }),
                         placeholder: choices?.placeholder ?? "Search commands, programs, tabs…",
                         label: "Command Palette Search", submit: activateSelection, move: move)
                .id(choices?.title ?? "commands")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var stepHeader: some View {
        HStack(spacing: 8) {
            Button(action: back) { Image(systemName: "chevron.left").frame(width: 22, height: 24) }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            Text(prompt?.title ?? choices?.title ?? "")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.top, 6)
    }

    private var resultList: some View {
        let groups = sections
        let rows = groups.flatMap(\.items)
        let contentHeight = groups.reduce(CGFloat.zero) { total, section in
            total + (section.title == nil ? 0 : 24) + section.items.reduce(0) { $0 + $1.rowHeight }
        }
        // Reserve the search, inline hints and optional Back header before
        // capping results, including in a short window.
        let listHeight = min(max(44, contentHeight), max(44, min(320, maxHeight - (choices == nil ? 100 : 130))))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // A stable scroll origin keeps headings visible when a query clears.
                    Color.clear.frame(height: 0).id("palette-top")
                    if rows.isEmpty {
                        Text("No matches").font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).frame(height: 44)
                    } else {
                        ForEach(groups) { section in
                            if let title = section.title {
                                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).frame(height: 24)
                            }
                            ForEach(section.items) { item in
                                PaletteRow(item: item, selected: selection == item.id) { activate(item) }
                                    .id(item.id)
                                    .onHover { if $0 && item.enabled { selectedID = item.id } }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .frame(height: listHeight)
            .onAppear { if let id = selectedID { proxy.scrollTo(id) } }
            .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            .onChange(of: query) { _, _ in if selectedID == nil { proxy.scrollTo("palette-top", anchor: .top) } }
            .onChange(of: choices?.title) { _, _ in proxy.scrollTo(selectedID ?? "palette-top", anchor: .top) }
        }
        .padding(.vertical, 6)
    }

    private func input(_ prompt: PalettePrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PaletteField(text: $value, placeholder: prompt.placeholder, label: prompt.title, submit: submit)
                .padding(9)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
            if let validation { Text(validation).font(.system(size: 12)).foregroundStyle(.orange) }
            let suggestions = prompt.suggestions.filter { value.isEmpty || $0.localizedCaseInsensitiveContains(value) }
            let suggestionCount = max(0, min(3, Int((maxHeight - (validation == nil ? 196 : 222)) / 32)))
            if !suggestions.isEmpty && suggestionCount > 0 {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(suggestions, id: \.self) { host in
                            Button { value = host; submit() } label: {
                                HStack { Image(systemName: "desktopcomputer"); Text(host); Spacer() }
                                    .font(.system(size: 14)).padding(7).contentShape(.rect)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: CGFloat(min(suggestionCount, suggestions.count)) * 32)
            }
            HStack {
                Spacer()
                Button(prompt.button, action: submit)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
        }
        .padding(12)
        .onChange(of: value) { _, _ in validation = nil }
    }

    /// Wraps around enabled results; the text field keeps IME candidate keys.
    private func move(_ delta: Int) {
        let available = results.filter(\.enabled)
        guard !available.isEmpty else { return }
        let index = selection.flatMap { id in available.firstIndex { $0.id == id } } ?? 0
        let item = available[(index + delta + available.count) % available.count]
        selectedID = item.id
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
                .announcement: [item.title, item.shortcut].filter { !$0.isEmpty }.joined(separator: ", "),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    private func activateSelection() {
        if let item = results.first(where: { $0.id == selection }) { activate(item) }
    }

    private func activate(_ item: PaletteItem) {
        guard item.enabled else { return }
        switch item.operation {
        case .perform(let action):
            remember(item.id)
            dismiss()
            action()
        case .prompt(let make):
            navigation.append(Location(choices: choices, query: query, selectedID: selectedID))
            pendingID = item.id
            prompt = make()
            value = prompt?.initial ?? ""
            validation = nil
        case .choices(let make):
            navigation.append(Location(choices: choices, query: query, selectedID: selectedID))
            choices = make()
            query = ""
            selectedID = nil
        }
    }

    private func submit() {
        guard let prompt else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = prompt.validate(trimmed) { validation = message; return }
        if let pendingID { remember(pendingID) }
        dismiss()
        prompt.submit(trimmed)
    }

    private func back() {
        guard let location = navigation.popLast() else { return }
        prompt = nil
        choices = location.choices
        pendingID = nil
        validation = nil
        query = location.query
        selectedID = location.selectedID
    }

    private func remember(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent, forKey: "paletteRecents")
    }
}

/// A plain text editor inside the custom card. Native editing commands route
/// arrows and Return reliably, while composed input keeps its candidate keys.
private struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let submit: () -> Void
    var move: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Input {
        let input = Input(string: text)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 14)
        input.textColor = .labelColor
        input.delegate = context.coordinator
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return input
    }

    func updateNSView(_ input: Input, context: Context) {
        context.coordinator.field = self
        input.placeholderString = placeholder
        input.setAccessibilityLabel(label)
        if input.stringValue != text { input.stringValue = text }
    }

    final class Input: NSTextField {
        /// Focus when attached, after the hosting view has installed the card.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: PaletteField
        init(_ field: PaletteField) { self.field = field }

        func controlTextDidChange(_ notification: Notification) {
            guard let input = notification.object as? NSTextField else { return }
            field.text = input.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                field.submit()
            case #selector(NSResponder.moveDown(_:)):
                guard let move = field.move else { return false }
                move(1)
            case #selector(NSResponder.moveUp(_:)):
                guard let move = field.move else { return false }
                move(-1)
            default: return false
            }
            return true
        }
    }
}

/// A compact keycap for the palette's bottom navigation hints.
private struct PaletteKeycap: View {
    let symbols: String

    var body: some View {
        Text(symbols)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 23, minHeight: 20)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
            .fixedSize()
    }
}

/// A compact result with a program tile or action glyph, metadata, and the
/// current shortcut or status. Disabled commands never become selections.
private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let style = item.style { ProgramTile(style: style, size: 24) }
                else { Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 24).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.destructive ? Color.red.opacity(0.9) : .primary)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                if !item.shortcut.isEmpty {
                    Text(item.shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let status = item.status, status != .idle {
                    Text(status == .blocked ? "Waiting" : status.rawValue.capitalized)
                        .font(.system(size: 11)).foregroundStyle(statusColor(status))
                } else if case .perform = item.operation {
                    EmptyView()
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: item.rowHeight)
            .background(Color.primary.opacity(selected ? 0.09 : 0), in: Capsule())
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.4)
    }

    private func statusColor(_ status: Wire.Status) -> Color {
        switch status {
        case .blocked: .orange
        case .error: .red
        case .done: .green
        default: .secondary
        }
    }
}

extension Action {
    /// Presentation metadata supplements the existing selector and keybinding;
    /// the palette never defines a second implementation of these actions.
    var paletteCategory: PaletteItem.Category {
        switch self {
        case .newWindow, .fullScreen: .window
        case .copy, .selectAll, .find, .clearScrollback, .resetTerminal, .previousPrompt, .nextPrompt, .insertPath, .goDirectory: .terminal
        case .saveProject, .openProject: .tabs
        case .showActivity: .terminal
        case .checkUpdates, .diagnostics: .settings
        case .newTab, .closeTab, .nextTab, .previousTab: .tabs
        case .closePane, .newSplit, .newSplitDown, .toggleZoom, .focusSplitLeft,
             .focusSplitRight, .focusSplitUp, .focusSplitDown, .nextPane, .previousPane: .panes
        case .toggleSidebar: .appearance
        case .increaseFontSize, .decreaseFontSize, .resetFontSize: .terminal
        case .openConfig, .reloadConfig, .commandPalette: .settings
        case .paste: .terminal
        }
    }

    var paletteSymbol: String {
        switch self {
        case .newWindow: "macwindow.badge.plus"
        case .copy: "doc.on.doc"
        case .selectAll: "selection.pin.in.out"
        case .find: "magnifyingglass"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        case .clearScrollback: "eraser"
        case .resetTerminal: "arrow.counterclockwise"
        case .previousPrompt: "arrow.up.to.line"
        case .nextPrompt: "arrow.down.to.line"
        case .insertPath: "doc.badge.plus"
        case .goDirectory: "folder"
        case .saveProject: "square.and.arrow.down"
        case .openProject: "folder"
        case .showActivity: "waveform.path"
        case .checkUpdates: "arrow.down.circle"
        case .diagnostics: "stethoscope"
        case .newTab: "plus"
        case .closeTab, .closePane: "xmark"
        case .newSplit: "rectangle.split.2x1"
        case .newSplitDown: "rectangle.split.1x2"
        case .toggleZoom: "arrow.up.left.and.arrow.down.right"
        case .focusSplitLeft, .previousPane, .previousTab: "arrow.left"
        case .focusSplitRight, .nextPane, .nextTab: "arrow.right"
        case .focusSplitUp: "arrow.up"
        case .focusSplitDown: "arrow.down"
        case .toggleSidebar: "sidebar.left"
        case .increaseFontSize, .decreaseFontSize, .resetFontSize: "textformat.size"
        case .paste: "clipboard"
        case .reloadConfig: "arrow.clockwise"
        case .openConfig: "gearshape"
        case .commandPalette: "command"
        }
    }
}
