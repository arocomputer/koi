import AppKit
import SwiftUI

extension View {
    /// Opens a Koi action menu at the pointer on secondary click, or from AX.
    func koiContextMenu(_ id: String, _ entries: [PopupEntry]) -> some View {
        modifier(PopupContextMenu(id: id, entries: entries))
    }
}

/// One command in a floating menu; a nil action makes a separator.
@MainActor struct PopupEntry {
    var title: String
    var symbol: String = ""
    var destructive = false
    var action: (() -> Void)?

    static let divider = PopupEntry(title: "")
}

private struct PopupContextMenu: ViewModifier {
    let id: String
    let entries: [PopupEntry]
    @State private var presented = false

    func body(content: Content) -> some View {
        if entries.isEmpty {
            content
        } else {
            content
                .background(PopupAnchor(isPresented: $presented, contextual: true, id: id,
                                        content: AnyView(PopupMenu(entries: entries))))
                .accessibilityAction(named: Text("Actions")) { presented = true }
        }
    }
}

private struct PopupDismissKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var dismissPopup: @MainActor () -> Void {
        get { self[PopupDismissKey.self] }
        set { self[PopupDismissKey.self] = newValue }
    }
}

/// A floating action list with pointer highlighting and arrow/Return control.
/// Long menus can cap their height; keyboard selection stays visible while scrolling.
struct PopupMenu: View {
    let entries: [PopupEntry]
    var maximumHeight: CGFloat? = nil
    @Environment(\.dismissPopup) private var dismiss
    @State private var selected: Int?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { scroll in
            Group {
                if let maximumHeight {
                    ScrollView { rows }
                        .frame(height: min(maximumHeight, CGFloat(entries.count) * 33 + 12))
                } else {
                    rows
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.return) { if let selected { perform(selected) }; return .handled }
            .onKeyPress(.space) { if let selected { perform(selected) }; return .handled }
            .onChange(of: selected) { _, index in
                if maximumHeight != nil, let index { scroll.scrollTo(index) }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 1) {
            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                if entry.action == nil {
                    Divider().opacity(0.5).padding(.horizontal, 6).padding(.vertical, 3)
                } else {
                    Button { perform(index) } label: {
                        HStack(spacing: 9) {
                            if !entry.symbol.isEmpty { Image(systemName: entry.symbol).frame(width: 18) }
                            Text(entry.title)
                            Spacer(minLength: 12)
                        }
                        .foregroundStyle(entry.destructive ? Color.red.opacity(0.9) : .primary)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.primary.opacity(selected == index ? 0.09 : 0),
                                    in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { selected = index } else if selected == index { selected = nil }
                    }
                    .id(index)
                }
            }
        }
        .font(.system(size: 14))
        .padding(6)
        .frame(width: 240)
    }

    private func move(_ offset: Int) {
        let choices = entries.indices.filter { entries[$0].action != nil }
        guard !choices.isEmpty else { return }
        let current = selected.flatMap { choices.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        selected = choices[(current + offset + choices.count) % choices.count]
    }

    private func perform(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let action = entries[index].action
        dismiss()
        action?()
    }
}

