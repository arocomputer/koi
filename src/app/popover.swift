import AppKit
import SwiftUI

/// The shared finish for notices and floating controls: soft glass, a faint
/// rim, and the toast's shadow. Callers choose a capsule or card radius.
struct FloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(Config.current.solidSurfaces
                ? AnyShapeStyle(Theme.current.backgroundColor) : AnyShapeStyle(.ultraThinMaterial),
                in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    }
}

extension View {
    /// Presents a Koi card below this control, keeping it inside its window.
    func koiPopup<Content: View>(isPresented: Binding<Bool>, id: String, @ViewBuilder content: () -> Content) -> some View {
        background(PopupAnchor(isPresented: isPresented, contextual: false, id: id, content: AnyView(content())))
    }


}

/// A transparent source view supplies window coordinates without intercepting
/// the SwiftUI control's normal clicks or drag gestures.
struct PopupAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let contextual: Bool
    let id: String
    let content: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        context.coordinator.anchor = view
        view.onAttach = { [weak coordinator = context.coordinator] in
            if coordinator?.wantsPresentation == true { coordinator?.show() }
        }
        view.onDetach = { [weak coordinator = context.coordinator] in coordinator?.dismiss(updateBinding: false) }
        if contextual { context.coordinator.watchSecondaryClicks() }
        #if KOID
        context.coordinator.watchPreview(id)
        #endif
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.dismissed = { isPresented = false }
        coordinator.requested = { isPresented = true }
        coordinator.wantsPresentation = isPresented
        coordinator.content = content
        if isPresented {
            coordinator.show()
        } else {
            coordinator.dismiss(updateBinding: false)
        }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.dismiss(updateBinding: false)
        if let monitor = coordinator.secondaryClick { NSEvent.removeMonitor(monitor) }
        #if KOID
        if let observer = coordinator.previewObserver { DistributedNotificationCenter.default().removeObserver(observer) }
        #endif
    }

    final class AnchorView: NSView {
        var onAttach: (() -> Void)?
        var onDetach: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            if window == nil { onDetach?() } else { onAttach?() }
        }
    }

    /// Owns one in-window overlay and restores focus when it closes. Only one
    /// root card is open at a time; a contextual menu can sit above a picker.
    @MainActor final class Coordinator {
        static weak var current: Coordinator?
        weak var anchor: NSView?
        /// Palettes sit below the title bar, centered in the owning window.
        var centered = false
        var isPresented: Bool { overlay != nil }
        var content = AnyView(EmptyView())
        var dismissed: (() -> Void)?
        /// A palette may outlive the pane that had focus when it opened.
        var fallbackResponder: (@MainActor () -> NSResponder?)?
        var requested: (() -> Void)?
        var wantsPresentation = false
        var secondaryClick: Any?
        #if KOID
        var previewObserver: NSObjectProtocol?
        #endif
        private weak var parentPopup: Coordinator?
        private var overlay: PopupOverlay?
        private var host: NSHostingView<AnyView>?
        private weak var previousResponder: NSResponder?
        private var monitors: [Any] = []
        private var observers: [NSObjectProtocol] = []
        private var point: NSPoint?
        private var scrollTravel: CGFloat = 0

        #if KOID
        /// Koid's CLI opens the real control without screen input or focus.
        func watchPreview(_ id: String) {
            previewObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.fschrhunt.koid.popup"), object: nil, queue: .main
            ) { [weak self] notification in
                let requestedID = notification.object as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if requestedID == "dismiss" { self.dismiss(); return }
                    guard requestedID == id, Self.current == nil, let anchor = self.anchor,
                          anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { return }
                    self.requested?()
                    self.show()
                }
            }
        }

        #endif

        /// Secondary and Control clicks open the menu at the pointer. While an
        /// unrelated card is open, that card's monitor dismisses it and opens
        /// this menu on the same press, whichever monitor AppKit runs first.
        func watchSecondaryClicks() {
            Self.contextual.add(self)
            secondaryClick = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let anchor = self.anchor, self.answers(event),
                      Self.current?.overlay.map({ anchor.isDescendant(of: $0) }) ?? true else { return event }
                self.open(at: event)
                return nil
            }
        }

        /// Every control with a context menu, so a dismissing press can find
        /// the menu it lands on without depending on monitor order.
        private static let contextual = NSHashTable<Coordinator>.weakObjects()

        /// Whether this control's menu answers a secondary click at the pointer.
        private func answers(_ event: NSEvent) -> Bool {
            guard let anchor, event.window === anchor.window, anchor.window != nil,
                  !anchor.isHiddenOrHasHiddenAncestor, overlay == nil, event.isKoiSecondaryClick else { return false }
            return anchor.koiExposes(event.locationInWindow)
        }

        private func open(at event: NSEvent) {
            point = event.locationInWindow
            requested?()
            show()
        }

        func show() {
            guard let anchor, let window = anchor.window, let parent = window.contentView else { return }
            let opening = overlay == nil
            if opening {
                TooltipAnchor.Coordinator.current?.dismiss()
                if let current = Self.current, let existing = current.overlay, anchor.isDescendant(of: existing) {
                    parentPopup = current
                } else {
                    Self.current?.dismiss()
                }
                Self.current = self
                previousResponder = window.firstResponder
                let overlay = PopupOverlay(frame: parent.bounds)
                overlay.autoresizingMask = [.width, .height]
                overlay.dismiss = { [weak self] in self?.dismiss() }
                let host = NSHostingView(rootView: AnyView(EmptyView()))
                host.safeAreaRegions = []
                overlay.addSubview(host)
                parent.addSubview(overlay)
                self.overlay = overlay
                self.host = host
                let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel], handler: { [weak self] event in
                    guard let self, Self.current === self, let overlay = self.overlay else { return event }
                    if event.type == .keyDown {
                        if event.keyCode == 53 {
                            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                            self.dismiss()
                            return nil
                        }
                    } else if event.type == .scrollWheel {
                        // Fingers settling for a physical two-finger press start a
                        // scroll gesture that never moves. Only travel dismisses.
                        guard self.scrollTravels(event), event.window !== overlay.window
                            || !overlay.cardContains(event.locationInWindow) else { return event }
                        self.dismiss()
                        return event
                    } else if event.window !== overlay.window || !overlay.cardContains(event.locationInWindow) {
                        self.dismiss()
                        if let next = Self.contextual.allObjects.first(where: { $0.answers(event) }) { next.open(at: event) }
                        return nil
                    }
                    return event
                })
                if let monitor { monitors.append(monitor) }
                for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.dismiss() }
                    })
                }
                observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
            }
            guard let host, let overlay else { return }
            // Establish the card's responder before its content requests text
            // focus; doing this afterwards steals focus from the search field.
            if opening { window.makeFirstResponder(host) }
            host.rootView = AnyView(content
                .environment(\.dismissPopup, { [weak self] in self?.dismiss() })
                .preferredColorScheme(.dark)
                .modifier(FloatingSurface())
                .padding(14)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.position(size)
                })
            position(host.fittingSize)
            overlay.card = host
        }

        /// A wheel notch or a few points of trackpad travel within one gesture
        /// count as scrolling; a gesture that only begins and ends does not.
        private func scrollTravels(_ event: NSEvent) -> Bool {
            if event.phase.contains(.mayBegin) || event.phase.contains(.began) { scrollTravel = 0 }
            scrollTravel += abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY)
            return event.hasPreciseScrollingDeltas ? scrollTravel >= 4 : scrollTravel > 0
        }

        private func position(_ size: CGSize) {
            guard let anchor, let parent = overlay?.superview, let host else { return }
            if centered {
                host.frame = NSRect(x: max(0, (parent.bounds.width - size.width) / 2),
                                    y: max(0, parent.bounds.height - size.height - AppDelegate.topRow),
                                    width: min(size.width, parent.bounds.width), height: min(size.height, parent.bounds.height))
                return
            }
            let source = point.map { NSRect(origin: parent.convert($0, from: nil), size: .zero) }
                ?? anchor.convert(anchor.bounds, to: parent)
            var y = source.minY - size.height + 8
            if y < 0 { y = source.maxY - 8 }
            host.frame = NSRect(x: min(max(0, source.minX - 14), max(0, parent.bounds.width - size.width)),
                                y: min(max(0, y), max(0, parent.bounds.height - size.height)),
                                width: min(size.width, parent.bounds.width), height: min(size.height, parent.bounds.height))
        }

        func dismiss(updateBinding: Bool = true) {
            guard let overlay else { return }
            if Self.current?.parentPopup === self { Self.current?.dismiss() }
            let window = overlay.window
            let responder = window?.firstResponder as? NSView
            let restoreFocus = centered || responder?.isDescendant(of: overlay) == true
            overlay.removeFromSuperview()
            self.overlay = nil
            host = nil
            point = nil
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if Self.current === self { Self.current = parentPopup }
            parentPopup = nil
            wantsPresentation = false
            if restoreFocus, let window {
                let valid = (previousResponder as? NSView).map { $0.window === window && !$0.isHiddenOrHasHiddenAncestor } ?? (previousResponder != nil)
                if !valid || !window.makeFirstResponder(previousResponder) {
                    window.makeFirstResponder(fallbackResponder?())
                }
            }
            if updateBinding { dismissed?() }
        }
    }
}

/// Captures the area around a card so dismissal never clicks through to a
/// terminal or starts a drag beneath it.
private final class PopupOverlay: NSView {
    weak var card: NSView?
    var dismiss: (() -> Void)?

    func cardContains(_ windowPoint: NSPoint) -> Bool {
        guard let card else { return false }
        return card.frame.insetBy(dx: 14, dy: 14).contains(convert(windowPoint, from: nil))
    }

    override func mouseDown(with event: NSEvent) { dismiss?() }
    override func rightMouseDown(with event: NSEvent) { dismiss?() }
}

extension NSWindow {
    /// Floating controls keep keyboard focus while terminal state refreshes.
    var hasKoiPopup: Bool { contentView?.subviews.contains { $0 is PopupOverlay } ?? false }
}

extension NSEvent {
    /// A right button, a two-finger trackpad press, or a Control-click.
    var isKoiSecondaryClick: Bool {
        type == .rightMouseDown || (type == .leftMouseDown && modifierFlags.contains(.control))
    }
}

extension View {
    /// A delayed, noninteractive hint that never becomes the keyboard responder.
    func koiTooltip(_ title: String, shortcut: Action? = nil) -> some View {
        modifier(ShortcutHint(title: title, shortcut: shortcut))
    }
}

/// Keep assistive text current when settings change, including persistent
/// title-bar controls whose SwiftUI parents do not otherwise need redrawing.
private struct ShortcutHint: ViewModifier {
    let title: String
    let shortcut: Action?
    @State private var symbols: String?

    func body(content: Content) -> some View {
        content.background(TooltipAnchor(title: title, shortcut: shortcut))
            .accessibilityLabel(title)
            .accessibilityHint(Text(symbols.map { "Shortcut: \($0)" } ?? ""))
            .onAppear { symbols = shortcut.map { Config.current.bind($0).symbols } }
            .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in
                symbols = shortcut.map { Config.current.bind($0).symbols }
            }
    }
}

/// Tracking lives in a transparent background so buttons keep their existing
/// hover, click and drag behavior. Hints use the same glass as floating menus.
struct TooltipAnchor: NSViewRepresentable {
    let title: String
    let shortcut: Action?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        context.coordinator.anchor = view
        view.hoverChanged = { [weak coordinator = context.coordinator] in coordinator?.hover($0) }
        #if KOID
        context.coordinator.watchPreview()
        #endif
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.title = title
        context.coordinator.shortcut = shortcut
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.dismiss()
        #if KOID
        if let observer = coordinator.previewObserver { DistributedNotificationCenter.default().removeObserver(observer) }
        #endif
    }

    /// Track the source control without becoming a pointer-event target.
    final class AnchorView: NSView {
        var hoverChanged: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
        override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { hoverChanged?(false) }
        }
    }

    /// Only one hint may be pending or visible. Leaving, typing, clicking,
    /// opening a menu or deactivating the window cancels it without consuming input.
    @MainActor final class Coordinator {
        static weak var current: Coordinator?
        weak var anchor: NSView?
        var title = ""
        var shortcut: Action?
        var shortcutSymbols: String? { shortcut.map { Config.current.bind($0).symbols } }
        var isPresented: Bool { host != nil }
        private var pending: Task<Void, Never>?
        private var host: NSView?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        #if KOID
        var previewObserver: NSObjectProtocol?

        /// Reuse Koid's popup preview channel: `popup hint:toggle_sidebar`.
        func watchPreview() {
            previewObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.fschrhunt.koid.popup"), object: nil, queue: .main
            ) { [weak self] notification in
                let id = notification.object as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if id == "dismiss" { self.dismiss(); return }
                    guard let shortcut = self.shortcut, id == "hint:\(shortcut.rawValue)" else { return }
                    self.hover(true)
                }
            }
        }
        #endif

        /// Start the hover delay, or cancel it immediately when the pointer leaves.
        func hover(_ inside: Bool) {
            guard inside else { dismiss(); return }
            guard let anchor, let window = anchor.window, !anchor.isHiddenOrHasHiddenAncestor,
                  anchor.koiExposes(anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)),
                  !window.hasKoiPopup else { return }
            if Self.current === self { return }
            Self.current?.dismiss()
            Self.current = self
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                self?.dismiss()
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.pending = nil
                self.show()
            }
        }

        /// Present after the delay, provided the control is still in a live window.
        private func show() {
            guard Self.current === self, let anchor, let window = anchor.window, let parent = window.contentView,
                  anchor.koiExposes(anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)),
                  !window.hasKoiPopup else { dismiss(); return }
            let content = HStack(spacing: 10) {
                Text(title).font(.system(size: 12.5))
                if let shortcutSymbols {
                    Text(shortcutSymbols).font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .modifier(FloatingSurface(cornerRadius: 9))
            .padding(14).fixedSize()
            .preferredColorScheme(.dark)
            .accessibilityHidden(true)
            let host = Host(rootView: AnyView(content))
            host.safeAreaRegions = []
            let size = host.fittingSize
            let source = anchor.convert(anchor.bounds, to: parent)
            var y = source.minY - size.height + 8
            if y < 0 { y = source.maxY - 8 }
            host.frame = NSRect(x: min(max(0, source.midX - size.width / 2), max(0, parent.bounds.width - size.width)),
                                y: min(max(0, y), max(0, parent.bounds.height - size.height)),
                                width: min(size.width, parent.bounds.width), height: min(size.height, parent.bounds.height))
            parent.addSubview(host)
            self.host = host
        }

        /// Remove the hint and its pending work without changing focus or input.
        func dismiss() {
            pending?.cancel()
            pending = nil
            host?.removeFromSuperview()
            host = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if Self.current === self { Self.current = nil }
        }
    }

    /// The hint is visual only: pointer events always reach the control below.
    private final class Host: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
