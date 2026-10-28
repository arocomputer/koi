import SwiftUI

/// Koi's Capsule style: a continuous rounded rectangle for selections and controls.
struct Capsule: InsettableShape {
    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    func path(in rect: CGRect) -> Path {
        shape.path(in: rect)
    }

    /// Keeps control rims inside the same rounded bounds as their backing.
    func inset(by amount: CGFloat) -> some InsettableShape {
        shape.inset(by: amount)
    }
}

/// Shared Capsule backing for category and tab selection; adds no layout or motion.
struct SelectionSurface: ViewModifier {
    let selected: Bool
    var hovering: Bool = false

    func body(content: Content) -> some View {
        content.background(Color.primary.opacity(selected ? 0.10 : hovering ? 0.06 : 0), in: Capsule())
    }
}

/// A button for the top row: a plain glyph that, hovered, gets the same
/// soft rounded highlight as a tab.
struct TopRowButton<Label: View>: View {
    let help: String
    var shortcut: Action?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .koiTooltip(help, shortcut: shortcut)
        .onHover { hovering = $0 }
    }
}

/// A borderless symbol button. Pane controls use a slightly larger glyph and
/// hit area than the compact tab controls.
struct IconButton: View {
    let symbol: String
    let help: String
    var shortcut: Action?
    var glyphSize: CGFloat = 10.5
    var controlSize: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: controlSize, height: controlSize)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .koiTooltip(help, shortcut: shortcut)
        .onHover { hovering = $0 }
    }
}

