import SwiftUI

/// Shared capsule backing for category selection; adds no layout or motion.
struct SelectionSurface: ViewModifier {
    let selected: Bool
    var hovering: Bool = false

    func body(content: Content) -> some View {
        content.background(Color.primary.opacity(selected ? 0.10 : hovering ? 0.06 : 0), in: Capsule())
    }
}

/// A top-row glyph with a circular hover highlight and a full square hit area.
struct TopRowButton<Label: View>: View {
    let help: String
    var shortcut: Action?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(hovering ? 0.06 : 0), in: Circle())
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .koiTooltip(help, shortcut: shortcut)
        .onHover { hovering = $0 }
        .animation(reduceMotion || Config.current.motion == .off ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// A symbol button with a circular hover highlight and a square hit area.
/// Pane controls are slightly larger than the compact tab controls.
struct IconButton: View {
    let symbol: String
    let help: String
    var shortcut: Action?
    var glyphSize: CGFloat = 10.5
    var controlSize: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: controlSize, height: controlSize)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: Circle())
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .koiTooltip(help, shortcut: shortcut)
        .onHover { hovering = $0 }
        .animation(reduceMotion || Config.current.motion == .off ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

