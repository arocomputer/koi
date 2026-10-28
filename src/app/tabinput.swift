import AppKit
import Observation
import SwiftUI

/// A strip's drop intent. Rows keep the server's order throughout a gesture;
/// only the root's release handler sends a move to the workspace.
@MainActor @Observable final class TabDrag {
    enum Target: Hashable { case tab(String), group(String), end }
    enum Placement: Equatable {
        case insert(String, after: Bool, outside: Bool)
        case intoGroup(String)
        case end
    }

    let horizontal: Bool
    private(set) var source: Wire.TabInfo?
    private(set) var active = false
    private(set) var placement: Placement?
    @ObservationIgnored private var point = CGPoint.zero
    @ObservationIgnored private var frames: [Target: (frame: CGRect, owner: UUID?)] = [:]
    @ObservationIgnored private var tree = Wire.State()
    @ObservationIgnored private var scroll = CGPoint.zero
    @ObservationIgnored private var escapeMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    init(horizontal: Bool) { self.horizontal = horizontal }

    isolated deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    /// Store live geometry in content coordinates so scrolling and subsequent
    /// geometry reports describe the same positions without frozen hit slots.
    func record(_ target: Target, frame: CGRect, owner: UUID? = nil) {
        guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else {
            if frames[target]?.owner == owner { removeFrame(target) }
            return
        }
        frames[target] = (frame.offsetBy(dx: scroll.x, dy: scroll.y), owner)
        if active { update(to: point) }
    }

    /// Reparenting can register a replacement before the old view disappears.
    /// Only the view that owns the current geometry may remove it.
    func remove(_ target: Target, owner: UUID) {
        guard frames[target]?.owner == owner else { return }
        removeFrame(target)
    }

    /// Return current viewport coordinates, including scroll displacement
    /// before SwiftUI delivers the next row geometry report.
    func frame(for target: Target) -> CGRect? {
        frames[target]?.frame.offsetBy(dx: -scroll.x, dy: -scroll.y)
    }

    /// Start only on a live tab's body. Headless callers install no keyboard
    /// monitor; a hosted gesture owns Escape only in its actual source window.
    func begin(at point: CGPoint, state: Wire.State, renaming: String?, window: NSWindow? = nil) {
        guard !active else { return }
        cancel()
        guard let tab = state.tabs.first(where: { tab in
            guard tab.id != renaming, let frame = frame(for: .tab(tab.id)) else { return false }
            return frame.contains(point) && point.x < frame.maxX - 28
        }) else { return }
        source = tab
        tree = state
        self.point = point
        active = true
        guard let window else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, self.active, let window, event.window === window, event.keyCode == 53 else { return event }
            self.cancel()
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    /// Resolve live targets without rearranging rows. Only an actual header
    /// hit joins a group; small gaps beside tabs share their insertion edges.
    func update(to point: CGPoint) {
        guard active, let source else { return }
        self.point = point
        let candidates = frames.compactMap { target, geometry -> (Target, CGRect)? in
            switch target {
            case .tab(let id): guard tree.tabs.contains(where: { $0.id == id }) else { return nil }
            case .group(let id):
                guard tree.items.contains(where: { if case .group(let group) = $0 { return group.id == id }; return false }) else { return nil }
            case .end: break
            }
            return (target, geometry.frame.offsetBy(dx: -scroll.x, dy: -scroll.y))
        }
        // Prefer the smaller target if a parent also reports overlapping bounds.
        let hit = candidates.filter { $0.1.contains(point) }
            .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
        let coordinate = axis(point)
        let nearest = candidates.filter { target, frame in
            guard case .tab = target else { return false }
            return frame.insetBy(dx: horizontal ? -6 : 0, dy: horizontal ? 0 : -6).contains(point)
        }.min { abs(axis(center($0.1)) - coordinate) < abs(axis(center($1.1)) - coordinate) }
        guard let (target, frame) = hit ?? nearest else { placement = nil; return }
        switch target {
        case .tab(let id):
            placement = id == source.id ? nil : .insert(id, after: coordinate > axis(center(frame)),
                                                      outside: outsideBoundary(id, at: point, frame: frame))
        case .group(let id): placement = .intoGroup(id)
        case .end: placement = .end
        }
    }

    /// Return one commit intent and immediately clear all gesture state.
    /// Layout after release comes exclusively from subsequent server state.
    func finish() -> (String, Placement)? {
        defer { cancel() }
        guard active, let source, let placement else { return nil }
        return (source.id, placement)
    }

    /// Metadata updates are harmless. A changed order or group membership
    /// cancels rather than committing an intent against a different tree.
    func reconcile(_ state: Wire.State) {
        guard active else { return }
        if Self.structure(state) != Self.structure(tree) { cancel() }
    }

    /// Clear intent and input ownership; the root keeps its started flag
    /// until release so cancellation cannot restart the same physical drag.
    func cancel() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        active = false
        source = nil
        placement = nil
        point = .zero
        tree = Wire.State()
    }

    /// Apply absolute offsets once; newly reported frames replace the same
    /// content positions rather than accumulating another scroll translation.
    func scrolled(to offset: CGPoint) {
        scroll = offset
        if active { update(to: point) }
    }

    /// The root clamps each step to the actual scroll extent. Leaving the
    /// viewport stops edge scrolling as well as invalidating release there.
    func scrollStep(in size: CGSize) -> CGFloat {
        guard active, CGRect(origin: .zero, size: size).contains(point) else { return 0 }
        let coordinate = axis(point), length = horizontal ? size.width : size.height
        let edge = min(28, length / 2)
        if coordinate < edge { return -7 }
        if coordinate > length - edge { return 7 }
        return 0
    }

    /// Removing a hidden source cancels; removing a destination immediately
    /// recomputes the cue so vanished rows cannot remain drop targets.
    private func removeFrame(_ target: Target) {
        frames[target] = nil
        if let source, target == .tab(source.id) { cancel() }
        else if active { update(to: point) }
    }

    /// The outer fifth of the first/last member explicitly extracts a tab
    /// to the top level; the rest of each member inserts inside its group.
    private func outsideBoundary(_ id: String, at point: CGPoint, frame: CGRect) -> Bool {
        for item in tree.items {
            guard case .group(let group) = item, group.tabs.contains(where: { $0.id == id }) else { continue }
            let coordinate = axis(point), length = horizontal ? frame.width : frame.height
            let lower = horizontal ? frame.minX : frame.minY, upper = horizontal ? frame.maxX : frame.maxY
            return (group.tabs.first?.id == id && coordinate < lower + length * 0.2)
                || (group.tabs.last?.id == id && coordinate > upper - length * 0.2)
        }
        return false
    }

    /// Project a viewport point onto the strip's ordering axis.
    private func axis(_ point: CGPoint) -> CGFloat { horizontal ? point.x : point.y }

    /// Use a target's midpoint to choose its leading or trailing insertion.
    private func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Compare topology only, allowing names and terminal metadata to update.
    private static func structure(_ state: Wire.State) -> [String] {
        state.items.flatMap { item in
            switch item {
            case .tab(let tab): [tab.id]
            case .group(let group): ["group:" + group.id] + group.tabs.map(\.id) + ["/group"]
            }
        }
    }
}

/// Record each view's owned geometry and paint drop feedback without moving
/// or hiding any row. Group targets belong on the header, including collapsed groups.
struct TabDragTarget: ViewModifier {
    let drag: TabDrag
    let target: TabDrag.Target
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabstrip")) } action: { drag.record(target, frame: $0, owner: owner) }
            .onDisappear { drag.remove(target, owner: owner) }
            .overlay {
                if case .intoGroup(let id) = drag.placement, target == .group(id) {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.75), lineWidth: 2)
                        .allowsHitTesting(false)
                } else if let after = insertionEdge {
                    Rectangle().fill(.white.opacity(0.75))
                        .frame(width: drag.horizontal ? 2 : nil, height: drag.horizontal ? nil : 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: drag.horizontal ? (after ? .trailing : .leading) : (after ? .bottom : .top))
                        .allowsHitTesting(false)
                }
            }
    }

    /// The end area marks its leading edge, with no reserved insertion gap.
    private var insertionEdge: Bool? {
        switch drag.placement {
        case .insert(let id, let after, _) where target == .tab(id): after
        case .end where target == .end: false
        default: nil
        }
    }
}

/// Own one same-window gesture, cancellation and bounded edge scrolling.
/// The content always renders the workspace's real server state.
struct TabStrip<Content: View>: View {
    let workspace: Workspace
    let drag: TabDrag
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition()
    @State private var size = CGSize.zero
    @State private var offset = CGPoint.zero
    @State private var extent = CGSize.zero
    @State private var windowAnchor = TabStripWindow.Anchor()
    @GestureState private var tracking = false
    @State private var started = false
    @State private var clickedTab: String?

    var body: some View {
        ScrollView(drag.horizontal ? .horizontal : .vertical) { content() }
            .scrollPosition($position)
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                offset = geometry.contentOffset
                extent = geometry.contentSize
                drag.scrolled(to: offset)
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .background(TabStripWindow(anchor: windowAnchor) { point, clicks in
                guard !drag.active, let tab = workspace.state.tabs.first(where: {
                    guard $0.id != workspace.renamingTab, let frame = drag.frame(for: .tab($0.id)) else { return false }
                    return frame.contains(point) && point.x < frame.maxX - 28
                }) else { clickedTab = nil; return }
                if clicks == 2, clickedTab == tab.id { workspace.renamingTab = tab.id }
                else { workspace.select(tab.id) }
                clickedTab = clicks == 1 ? tab.id : nil
            })
            .coordinateSpace(name: "tabstrip")
            .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("tabstrip"))
                .updating($tracking) { _, value, _ in value = true }
                .onChanged { value in
                    if !started {
                        started = true
                        drag.begin(at: value.startLocation, state: workspace.state, renaming: workspace.renamingTab,
                                   window: windowAnchor.window)
                    }
                    drag.update(to: value.location)
                }
                .onEnded { value in
                    started = false
                    guard CGRect(origin: .zero, size: size).contains(value.location) else { drag.cancel(); return }
                    drag.update(to: value.location)
                    if let (id, placement) = drag.finish() {
                        workspace.commitTabDrag(id, placement: placement) { _ in }
                    }
                })
            .onChange(of: tracking) { _, tracking in
                if !tracking { started = false; drag.cancel() }
            }
            .onChange(of: workspace.state) { _, state in drag.reconcile(state) }
            .onChange(of: ObjectIdentifier(workspace)) { clickedTab = nil; drag.cancel() }
            .onReceive(NotificationCenter.default.publisher(for: Config.didReload)) { _ in clickedTab = nil; drag.cancel() }
            .onDisappear { clickedTab = nil; drag.cancel() }
            .task(id: drag.active) {
                while drag.active, !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    guard drag.active, !Task.isCancelled else { return }
                    let step = drag.scrollStep(in: size)
                    guard step != 0 else { continue }
                    if drag.horizontal {
                        let next = min(max(0, offset.x + step), max(0, extent.width - size.width))
                        if next != offset.x { position.scrollTo(x: next) }
                    } else {
                        let next = min(max(0, offset.y + step), max(0, extent.height - size.height))
                        if next != offset.y { position.scrollTo(y: next) }
                    }
                }
            }
    }
}

/// One native click observer per strip selects on mouse-down, as native tab
/// bars do, so switching is as immediate as a shortcut rather than waiting for
/// the release. AppKit's click count on the second press recognizes a rename,
/// without delaying embedded close buttons.
struct TabStripWindow: NSViewRepresentable {
    let anchor: Anchor
    let clicked: (CGPoint, Int) -> Void

    /// Keep one anchor identity for the lifetime of this strip.
    func makeNSView(context: Context) -> Anchor { anchor.clicked = clicked; return anchor }

    /// Refresh callbacks when the displayed workspace changes.
    func updateNSView(_ view: Anchor, context: Context) { view.clicked = clicked }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop(); view.clicked = nil }

    /// Let the scroll view and its controls receive all pointer events.
    final class Anchor: NSView {
        var clicked: ((CGPoint, Int) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Observe only this strip's window, leaving normal control and drag
        /// dispatch intact: the event continues to whatever it was aimed at.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !window.hasKoiPopup, self.koiExposes(event.locationInWindow) else { return event }
                self.clicked?(self.convert(event.locationInWindow, from: nil), event.clickCount)
                return event
            }
        }

        /// Removal releases the window-local observer.
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
