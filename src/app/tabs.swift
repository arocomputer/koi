import SwiftUI

/// A vertical glass rail shared by left and right placement. The title-bar
/// controls live in AppDelegate; only the scrolling tabs and groups live here.
struct SidebarView: View {
    let machines: Machines
    private var workspace: Workspace { machines.workspace }
    @State private var drag: TabDrag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = Config.current.motion

    init(machines: Machines, drag: TabDrag? = nil) {
        self.machines = machines
        _drag = State(initialValue: drag ?? TabDrag(horizontal: false))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: AppDelegate.topRow)
            ScrollViewReader { scroll in
                TabStrip(workspace: workspace, drag: drag) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(workspace.state.items) { item in
                            switch item {
                            case .tab(let tab):
                                TabItem(tab: tab, workspace: workspace, drag: drag, horizontal: false).id(tab.id)
                            case .group(let group):
                                VStack(alignment: .leading, spacing: 4) {
                                    TabGroupLabel(group: group, workspace: workspace, drag: drag, horizontal: false)
                                        .id("group:" + group.id)
                                    if !workspace.collapsed.contains(group.id) {
                                        ForEach(group.tabs) { tab in
                                            TabItem(tab: tab, workspace: workspace, drag: drag, horizontal: false)
                                                .padding(.leading, 6)
                                                .id(tab.id)
                                        }
                                    }
                                }
                                .padding(.top, 5)
                                .transition(.identity)
                            }
                        }
                        TabEndTarget(drag: drag)
                    }
                    .padding(.horizontal, 8)
                    .animation(stripAnimation(motion, reduceMotion: reduceMotion || drag.active), value: stripTopology(workspace))
                    .transaction { transaction in
                        if drag.active || reduceMotion || motion == .off { transaction.disablesAnimations = true; transaction.animation = nil }
                    }
                }
                .id(machines.current)
                .onChange(of: selectedStripTarget(workspace), initial: true) { _, id in
                    if let id, !drag.active { scroll.scrollTo(id) }
                }
            }
            .layoutPriority(1)
        }
        .onChange(of: machines.current) { drag.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in
            drag.cancel()
            motion = Config.current.motion
        }
    }
}

/// Horizontal tabs expand the selection to its natural width within the viewport.
/// Selection and row geometry share the selection spring; topology uses a short ease.
struct HorizontalBar: View {
    let machines: Machines
    private var workspace: Workspace { machines.workspace }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = TabDrag(horizontal: true)
    @Namespace private var selectionSpace
    @State private var viewportWidth: CGFloat = 194
    @State private var motion = Config.current.motion

    init(machines: Machines, drag: TabDrag? = nil) {
        self.machines = machines
        _drag = State(initialValue: drag ?? TabDrag(horizontal: true))
    }

    var body: some View {
        let items = workspace.state.items
        let topology = stripTopology(workspace)
        HStack(spacing: 8) {
            MachineButton(machines: machines)
            Group {
                TabStrip(workspace: workspace, drag: drag, revealTarget: selectedStripTarget(workspace)) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            switch item {
                            case .tab(let tab):
                                TabItem(tab: tab, workspace: workspace, drag: drag, horizontal: true,
                                        maximumWidth: max(1, viewportWidth - 4), selectionSpace: selectionSpace).id(tab.id)
                            case .group(let group):
                                HStack(spacing: 4) {
                                    TabGroupLabel(group: group, workspace: workspace, drag: drag, horizontal: true)
                                        .id("group:" + group.id)
                                    if !workspace.collapsed.contains(group.id) {
                                        ForEach(group.tabs) { tab in
                                            TabItem(tab: tab, workspace: workspace, drag: drag, horizontal: true,
                                                    maximumWidth: max(1, viewportWidth - 12), selectionSpace: selectionSpace).id(tab.id)
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                                .transition(.identity)
                            }
                        }
                        TabEndTarget(drag: drag)
                    }
                    .padding(.trailing, 4)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { viewportWidth = $0 }
                .background {
                    GeometryReader { geometry in
                        let leading = max(0, geometry.frame(in: .global).minX)
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .modifier(GlassTabSurface(selected: true, horizontal: true))
                                .matchedGeometryEffect(id: machines.current, in: selectionSpace, isSource: false)
                                .frame(width: 0, height: 0)
                                .opacity(selectionIsVisible ? 1 : 0)
                        }
                        // Include the header to the left so the first tab can
                        // overshoot, while keeping the trailing controls clear.
                        .frame(width: geometry.size.width + leading, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                        .offset(x: -leading)
                    }
                    .allowsHitTesting(false)
                }
                .animation(stripAnimation(motion, reduceMotion: reduceMotion || drag.active), value: topology)
                .animation(selectionSpring(motion, reduceMotion: reduceMotion || drag.active), value: workspace.selectedTab)
                .animation(nil, value: drag.active)
                .animation(nil, value: motion)
                .animation(nil, value: reduceMotion)
                .transaction { transaction in
                    if drag.active || reduceMotion || motion == .off { transaction.disablesAnimations = true; transaction.animation = nil }
                }
                .id(machines.current)
                .onChange(of: machines.current) { drag.cancel() }
                .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in
                    drag.cancel()
                    motion = Config.current.motion
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                TopRowButton(help: "Command Palette", shortcut: .commandPalette, action: {
                    NSApp.sendAction(Action.commandPalette.selector, to: nil, from: nil)
                }) {
                    Image(systemName: "command").font(.system(size: 14, weight: .medium))
                }
                TopRowButton(help: "New Tab", shortcut: .newTab, action: { workspace.newTab() }) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                }
            }
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var selectionIsVisible: Bool {
        guard let id = workspace.selectedTab, let found = workspace.tab(id) else { return false }
        return found.group.map { !workspace.collapsed.contains($0.id) } ?? true
    }

}

/// Selection may bounce; structural changes always settle without overshoot.
private func selectionSpring(_ motion: Config.Motion, reduceMotion: Bool) -> Animation? {
    guard !reduceMotion, motion != .off else { return nil }
    return .bouncy(duration: motion == .snappy ? 0.22 : 0.32)
}

private func stripAnimation(_ motion: Config.Motion, reduceMotion: Bool) -> Animation? {
    guard !reduceMotion, motion != .off else { return nil }
    return .easeOut(duration: motion == .snappy ? 0.12 : 0.18)
}

/// Metadata changes do not disturb motion. Collapsing, grouping and removal do.
@MainActor private func stripTopology(_ workspace: Workspace) -> [String] {
    workspace.state.items.flatMap { item -> [String] in
        switch item {
        case .tab(let tab): return ["tab:" + tab.id]
        case .group(let group):
            return ["group:" + group.id] + (workspace.collapsed.contains(group.id) ? [] : group.tabs.map { "tab:" + $0.id })
        }
    }
}

/// Tab behavior and Capsule styling are shared across placements. Horizontal
/// selection belongs to the bar; vertical rows paint their own selection.
private struct TabItem: View {
    let tab: Wire.TabInfo
    let workspace: Workspace
    let drag: TabDrag
    let horizontal: Bool
    var maximumWidth: CGFloat = 190
    var selectionSpace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = Config.current.motion
    @State private var hovering = false
    @State private var editName = ""
    @State private var grouping = false
    @FocusState private var nameFocused: Bool

    private var selected: Bool { workspace.selectedTab == tab.id }
    private var displayName: String? { workspace.pendingTabNames[tab.id] ?? tab.name }
    private var renaming: Bool {
        workspace.renamingTab == tab.id && horizontal == (Config.current.tabs == .top)
    }

    var body: some View {
        let tab = workspace.presentedTab(self.tab)
        let pane = workspace.focusedPane(in: tab)
        let style = Programs.style(for: pane)
        let label = horizontal ? TabLabel.make(pane, style) : TabLabel.tab(pane, style)
        let styles = [style] + tab.layout.panes.filter { $0 != pane?.id }.compactMap { tab.pane($0) }
            .map { Programs.style(for: $0) }
        HStack(spacing: 8) {
            Group {
                if horizontal && styles.count > 1 {
                    TileStack(styles: styles)
                } else {
                    ProgramTile(style: style, size: ProgramTile.tabSize)
                }
            }
            .overlay(alignment: .topTrailing) {
                if workspace.hasAgentCompletion(in: self.tab) {
                    Circle().fill(.green)
                        .frame(width: 7, height: 7)
                        .overlay { Circle().stroke(Theme.current.backgroundColor, lineWidth: 1.5) }
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(displayName?.isEmpty == false ? displayName! : label.title)
                        .fontWeight(horizontal ? (selected ? .medium : .regular) : (selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(minWidth: 0, alignment: .leading)
                        .layoutPriority(1)
                    if displayName?.isEmpty != false, !label.detail.isEmpty {
                        Text(label.detail).foregroundStyle(.tertiary).truncationMode(.head)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .clipped()
            .opacity(renaming ? 0 : 1)
            .accessibilityHidden(renaming)
            .overlay {
                if renaming {
                    TextField("Tab name", text: $editName)
                        .textFieldStyle(.plain).focused($nameFocused)
                        .onAppear { editName = displayName ?? ""; nameFocused = true }
                        .onSubmit { commitName(restoreFocus: true) }
                        .onExitCommand { endRename(in: workspace, group: false, restoreFocus: true) }
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName(restoreFocus: false) } }
                        .transition(.opacity)
                }
            }
            .animation(stripAnimation(motion, reduceMotion: reduceMotion), value: renaming)
            if !horizontal && tab.panes.count > 1 {
                Text("\(tab.panes.count)").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            trailing(pane).frame(width: 22, height: 22)
        }
        .font(.system(size: 13))
        .padding(.leading, 10)
        .padding(.trailing, horizontal ? 6 : 5)
        .frame(height: horizontal ? 32 : 34)
        .frame(minWidth: horizontal ? (selected ? min(190, maximumWidth) : 190) : nil,
               maxWidth: horizontal ? (selected ? maximumWidth : 190) : nil)
        .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        // Move the caption, tile and controls in one geometry space during reflow.
        .geometryGroup()
        .background {
            if horizontal && selected, let selectionSpace {
                Color.clear.matchedGeometryEffect(id: workspace.endpoint, in: selectionSpace)
            }
        }
        .modifier(GlassTabSurface(selected: !horizontal && selected,
                                 hovering: hovering && !drag.active && (!horizontal || !selected), horizontal: horizontal))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in motion = Config.current.motion }
        .modifier(TabDragTarget(drag: drag, target: .tab(tab.id)))
        .transition(.identity)
        .koiContextMenu("tab", menu)
        .koiPopup(isPresented: $grouping, id: "group-tab-\(tab.id)") {
            TabGroupingMenu(tab: tab, workspace: workspace)
        }
        .accessibilityLabel(displayName?.isEmpty == false ? displayName! : "\(label.title) \(label.detail)")
        .accessibilityValue([selected ? "Selected" : "", workspace.hasAgentCompletion(in: tab) ? "Agent finished" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { workspace.select(tab.id) }
    }

    /// Crossfade the reserved close/status slot without moving the tab's caption.
    @ViewBuilder private func trailing(_ pane: Wire.PaneInfo?) -> some View {
        let showClose = hovering && !renaming && !drag.active
        ZStack {
            if !horizontal {
                Group {
                    switch pane?.status {
                    case .working: WorkingDots()
                    case .blocked: StatusDot(color: .orange)
                    case .error: StatusDot(color: .red)
                    default: EmptyView()
                    }
                }
                .opacity(showClose ? 0 : 1)
            }
            IconButton(symbol: "xmark", help: "Close Tab", shortcut: .closeTab) { workspace.closeTab(tab.id) }
                .disabled(!showClose)
                .opacity(showClose ? 1 : 0)
                .allowsHitTesting(showClose)
                .accessibilityHidden(!showClose)
        }
        .animation(reduceMotion || motion == .off ? nil : .easeOut(duration: 0.12), value: showClose)
    }

    private var menu: [PopupEntry] {
        var entries: [PopupEntry] = [
            .init(title: "Rename…", symbol: "pencil", action: { workspace.renamingTab = tab.id }),
            .init(title: "Move or Group…", symbol: "folder", action: { grouping = true }),
        ]
        if displayName?.isEmpty == false {
            entries.append(.init(title: "Clear Name", symbol: "eraser", action: { workspace.renameTab(tab.id, to: "") }))
        }
        if workspace.tab(tab.id)?.group != nil {
            entries.append(.init(title: "Move Out of Group", symbol: "rectangle", action: { workspace.dropAtEnd(tab.id) }))
        }
        entries += [.divider,
            .init(title: "New Tab", symbol: "plus", action: { workspace.newTab() }),
            .init(title: "Close Tab", symbol: "xmark", destructive: true, action: { workspace.closeTab(tab.id) }),
            .init(title: "Close Other Tabs", symbol: "rectangle.stack", destructive: true,
                  action: { workspace.closeOtherTabs(tab.id) })]
        return entries
    }

    private func commitName(restoreFocus: Bool) {
        guard renaming else { return }
        endRename(in: workspace, group: false, restoreFocus: restoreFocus)
        let name = editName.trimmingCharacters(in: .whitespaces)
        if name != (displayName ?? "") { workspace.renameTab(tab.id, to: name) }
    }
}

/// Restores the tab-only glass finish without changing selection geometry or motion.
private struct GlassTabSurface: ViewModifier {
    let selected: Bool
    var hovering = false
    var horizontal = false
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reduceTransparency = Config.current.reduceTransparency
    @State private var motion = Config.current.motion

    func body(content: Content) -> some View {
        content.background {
            if selected {
                if horizontal {
                    Capsule().fill(Color.primary.opacity(0.13))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                } else {
                    Capsule().fill(LinearGradient(colors: [Color.primary.opacity(0.09), Color.primary.opacity(0.035)],
                                                 startPoint: .top, endPoint: .bottom))
                        .background(reduceTransparency || systemReduceTransparency
                            ? AnyShapeStyle(Theme.current.backgroundColor) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.17), lineWidth: 0.75))
                        .clipShape(Capsule())
                        .onAppear { reduceTransparency = Config.current.reduceTransparency }
                        .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in
                            reduceTransparency = Config.current.reduceTransparency
                        }
                }
            } else {
                Capsule().fill(Color.primary.opacity(horizontal ? 0.06 : 0.045))
                    .opacity(hovering ? 1 : 0)
                    .animation(reduceMotion || motion == .off ? nil : .easeOut(duration: 0.12), value: hovering)
                    .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in motion = Config.current.motion }
            }
        }
    }
}

/// A tab's pane tiles form a stable fan with the focused pane in front.
private struct TileStack: View {
    let styles: [ProgramStyle]
    private let size = ProgramTile.tabSize

    var body: some View {
        let shown = Array(styles.prefix(3).enumerated())
        ZStack(alignment: .leading) {
            ForEach(shown.reversed(), id: \.offset) { index, style in
                ProgramTile(style: style, size: size)
                    .brightness(-0.05 * Double(index))
                    .rotationEffect(.degrees(Double(index) * 11))
                    .offset(x: CGFloat(index) * size * 0.33)
                    .zIndex(Double(-index))
            }
        }
        .frame(width: size * 1.14 + CGFloat(max(shown.count - 1, 0)) * size * 0.42, alignment: .leading)
    }
}

/// Group headers expose collapse, rename and an explicit drop target.
/// A collapsed header keeps its hidden selected tab discoverable.
private struct TabGroupLabel: View {
    let group: Wire.GroupInfo
    let workspace: Workspace
    let drag: TabDrag
    let horizontal: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = Config.current.motion
    @State private var name = ""
    @FocusState private var focused: Bool
    private var displayName: String { workspace.pendingGroupNames[group.id] ?? group.name }

    private var renaming: Bool {
        workspace.renamingGroup == group.id && horizontal == (Config.current.tabs == .top)
    }
    private var containsHiddenSelection: Bool {
        workspace.collapsed.contains(group.id) && group.tabs.contains { $0.id == workspace.selectedTab }
    }

    var body: some View {
        HStack(spacing: 5) {
            Button { workspace.toggleCollapsed(group.id) } label: {
                Image(systemName: workspace.collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(workspace.collapsed.contains(group.id) ? "Expand" : "Collapse") \(displayName)")
            Text(displayName.isEmpty ? "Untitled" : displayName).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(renaming ? 0 : 1)
                .accessibilityHidden(renaming)
                .onTapGesture(count: 2) { workspace.renamingGroup = group.id }
                .overlay {
                    if renaming {
                        TextField("Group name", text: $name).textFieldStyle(.plain).focused($focused)
                            .onAppear { name = displayName; focused = true }
                            .onSubmit { commit(restoreFocus: true) }
                            .onExitCommand { endRename(in: workspace, group: true, restoreFocus: true) }
                            .onChange(of: focused) { _, focused in if !focused { commit(restoreFocus: false) } }
                            .transition(.opacity)
                    }
                }
                .animation(stripAnimation(motion, reduceMotion: reduceMotion), value: renaming)
            if !horizontal { Spacer(minLength: 0) }
            if !horizontal { Text("\(group.tabs.count)").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .font(.system(size: horizontal ? 12 : 11.5, weight: .semibold))
        .foregroundStyle(containsHiddenSelection ? .primary : .secondary)
        .padding(.horizontal, 5)
        .frame(width: horizontal ? 110 : nil, height: horizontal ? 32 : 24)
        .contentShape(.rect)
        .modifier(GlassTabSurface(selected: containsHiddenSelection, horizontal: horizontal))
        .background(Color.primary.opacity(drag.placement == .intoGroup(group.id) ? 0.1 : 0), in: Capsule())
        .modifier(TabDragTarget(drag: drag, target: .group(group.id)))
        .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in motion = Config.current.motion }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(displayName.isEmpty ? "Untitled Group" : displayName)
        .accessibilityValue(selectionDescription)
        .koiContextMenu("group", [
            .init(title: "Rename…", symbol: "pencil", action: { workspace.renamingGroup = group.id }),
            .init(title: workspace.collapsed.contains(group.id) ? "Expand" : "Collapse", symbol: "chevron.right",
                  action: { workspace.toggleCollapsed(group.id) }),
            .init(title: "Ungroup", symbol: "rectangle.3.group", action: { workspace.ungroup(group.id) }),
            .divider,
            .init(title: "Close Group", symbol: "xmark", destructive: true, action: { workspace.closeGroup(group.id) })
        ])
    }

    /// A collapsed group's header preserves the hidden selected tab's identity.
    private var selectionDescription: String {
        guard containsHiddenSelection, let tab = group.tabs.first(where: { $0.id == workspace.selectedTab }) else {
            return "\(group.tabs.count) tabs"
        }
        let pane = workspace.focusedPane(in: workspace.presentedTab(tab))
        let style = Programs.style(for: pane)
        let label = TabLabel.tab(pane, style)
        return "Selected tab: \(tab.name?.isEmpty == false ? tab.name! : label.title + " " + label.detail)"
    }

    private func commit(restoreFocus: Bool) {
        guard renaming else { return }
        endRename(in: workspace, group: true, restoreFocus: restoreFocus)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != displayName { workspace.renameGroup(group.id, to: trimmed) }
    }
}

/// Explicit completion returns focus to the terminal; blur preserves its new owner.
/// An open menu or palette keeps focus for its own card.
@MainActor func endRename(in workspace: Workspace, group: Bool, restoreFocus: Bool) {
    if group { workspace.renamingGroup = nil } else { workspace.renamingTab = nil }
    guard restoreFocus, let view = workspace.selectedView, let window = view.window,
          window.firstResponder !== view, !window.hasKoiPopup else { return }
    window.makeFirstResponder(view)
}

/// Hidden selected tabs scroll to their collapsed header in either orientation.
@MainActor private func selectedStripTarget(_ workspace: Workspace) -> String? {
    guard let id = workspace.selectedTab else { return nil }
    if let group = workspace.tab(id)?.group, workspace.collapsed.contains(group.id) { return "group:" + group.id }
    return id
}

/// Group creation is an explicit menu choice, never a side effect of hovering
/// over a tab while trying to reorder it. Existing groups are named targets.
private struct TabGroupingMenu: View {
    let tab: Wire.TabInfo
    let workspace: Workspace

    private var entries: [PopupEntry] {
        var result: [PopupEntry] = []
        for item in workspace.state.items {
            switch item {
            case .group(let group) where group.id != workspace.tab(tab.id)?.group?.id:
                result.append(.init(title: "Move to \(group.name.isEmpty ? "Untitled Group" : group.name)", symbol: "folder",
                                    action: { workspace.drop(tab.id, intoGroup: group.id) }))
            case .tab(let target) where target.id != tab.id:
                let pane = workspace.focusedPane(in: workspace.presentedTab(target))
                let style = Programs.style(for: pane)
                let caption = TabLabel.tab(pane, style)
                result.append(.init(title: "Group with \(target.name?.isEmpty == false ? target.name! : caption.title + " " + caption.detail)",
                                    symbol: "rectangle.stack", action: { workspace.drop(tab.id, onto: target.id) }))
            default: break
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move or Group Tab").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 4)
            if entries.isEmpty {
                Text("Create another tab to make a group.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(14)
            } else {
                PopupMenu(entries: entries, maximumHeight: 310)
            }
        }
        .frame(width: 260)
    }
}

/// The trailing/bottom strip space is an explicit way to leave a group.
private struct TabEndTarget: View {
    let drag: TabDrag
    var body: some View {
        Color.clear.frame(width: drag.horizontal ? 36 : nil, height: drag.horizontal ? 34 : 46)
            .contentShape(.rect)
            .modifier(TabDragTarget(drag: drag, target: .end))
    }
}

/// What a tab is called, from the pane it stands for.
enum TabLabel {
    /// Tab captions put the program first and keep its directory secondary;
    /// pane headers continue using their existing contextual title below.
    static func tab(_ pane: Wire.PaneInfo?, _ style: ProgramStyle) -> (title: String, detail: String) {
        guard let pane else { return ("…", "") }
        if pane.program.isEmpty { return (style.name, Paths.tilde(pane.cwd, home: pane.home ?? NSHomeDirectory())) }
        return make(pane, style)
    }
    /// What a tab or pane is called: a program's own title when it sets one
    /// (Claude Code and Codex title their tasks), a running program's name
    /// and directory, or for a shell at its prompt the directory and the
    /// shell (`~/apps/web — fish`).
    static func make(_ pane: Wire.PaneInfo?, _ style: ProgramStyle) -> (title: String, detail: String) {
        guard let pane else { return ("…", "") }
        let dir = Paths.tilde(pane.cwd, home: pane.home ?? NSHomeDirectory())
        if pane.program.isEmpty { return (dir, "— " + style.name) }
        let title = cleanTitle(pane.title)
        if !title.isEmpty, title != pane.program { return (title, "") }
        return (style.name, dir)
    }

    /// A title without the spinners and status glyphs programs put first.
    private static func cleanTitle(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }
}


/// Three dots that pulse in turn: the program is working.
private struct WorkingDots: View {
    @State private var motion = Config.current.motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || motion == .off)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3) { i in
                    let phase = (sin((t * 5) - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .frame(width: 4, height: 4)
                        .opacity(reduceMotion || motion == .off ? 0.6 : 0.3 + phase * 0.6)
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: 22)
        .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in motion = Config.current.motion }
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).frame(width: 22)
    }
}
