import AppKit
import SwiftUI

/// A small notice that fades in a corner: shortcut hints and config reloads.
/// Its glass finish is shared with Koi's floating menus and pickers.
struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .modifier(FloatingSurface(cornerRadius: 100))
    }

    /// Present and retire a notice in its owning window without taking focus.
    @MainActor static func show(_ text: String, in parent: NSView) {
        let toast = NSHostingView(rootView: Toast(text: text))
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.safeAreaRegions = []
        toast.alphaValue = 0
        parent.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
            toast.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -16),
        ])
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; toast.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.45; toast.animator().alphaValue = 0 },
                                                 completionHandler: { Task { @MainActor in toast.removeFromSuperview() } })
        }
    }
}
