import AppKit
import SwiftUI
import QuartzCore

/// A tab's pane cards and dividers. Owns interruptible layout motion, never
/// terminal sessions. Live terminals take their final size once; motion changes
/// only position and opacity. External resize holds retain independent owners.
@MainActor
final class SplitContainerView: NSView {
    /// Pane intents stay with the coordinator/workspace that owns the session.
    struct Actions {
        var split: (Wire.Direction) -> Void
        var zoom: () -> Void
        var close: () -> Void
        var focus: (String) -> Void
        /// Resizes the pair on either side of a split's divider (by index).
        var resize: (String, Int, Double) -> Void
        /// Swaps a pane with the one its header was dragged onto.
        var swap: (String, String) -> Void
        var dragChanged: (String, CGSize) -> Void
        var dragEnded: (String, CGSize) -> Void
    }

    static var gap: CGFloat { Config.current.compactPanes ? 4 : 8 }
    var actions: Actions?
    /// Called after live surfaces and temporary envelopes move. Chrome reads
    /// `surfaceRects` here to keep paint masks and input coverage synchronized.
    var onSurfaceLayout: (() -> Void)?
    private var tab: Wire.TabInfo?
    private var zoomed: String?
    private var cards: [String: PaneCard] = [:]
    /// Terminal identity also scopes cards to their workspace. The coordinator
    /// prunes this cache against all live workspace views after state changes.
    private var cachedCards: [ObjectIdentifier: PaneCard] = [:]
    private var dividers: [DividerKey: DividerView] = [:]
    private var resizeHolds: [UUID: [TerminalView]] = [:]
    private var paneIDs: [String] = []
    private var appearing: Set<String> = []
    private var animateNextLayout = false
    private var layoutTransitionActive = false
    private var layoutTransitionSize: NSSize?
    private var transitionShell: PaneTransitionShell?
    private var appearanceObserver: NSObjectProtocol?
    private var slotFrames: [String: NSRect] = [:]

    /// Pending weights survive metadata, focus and stale server echoes. Child
    /// membership invalidates them; a proportional server echo confirms them.
    private struct SplitKey: Hashable {
        let id: String
        let terminals: [ObjectIdentifier]
    }
    private struct PendingWeights {
        let children: [[String]]
        var weights: [Double]
        var dragging: Bool
    }
    private var draggedWeights: [SplitKey: PendingWeights] = [:]

    private struct DividerKey: Hashable {
        let split: String
        let index: Int
    }
    private struct DividerSlot {
        let key: DividerKey
        let split: SplitKey
        let direction: Wire.Direction
        let frame: NSRect
        let within: NSRect
    }

    /// One clock drives both frames and opacity, so retargeting starts at the
    /// current visible values and has no obsolete completion to run later.
    private struct Motion {
        let card: PaneCard
        let from: NSRect
        let to: NSRect
        let fromAlpha: CGFloat
        let toAlpha: CGFloat
        let hide: Bool
    }
    private var motion: [Motion] = []
    private var motionStarted: TimeInterval = 0
    private var motionDuration: TimeInterval = 0
    private var motionDisplayLink: CADisplayLink?
    private var motionDeadline: TimeInterval?

    /// CADisplayLink retains its target. Keep the owner weak so the clock
    /// cannot prevent container teardown and the release of terminal holds.
    @MainActor private final class MotionTarget: NSObject {
        weak var owner: SplitContainerView?

        init(_ owner: SplitContainerView) {
            self.owner = owner
            super.init()
        }

        @objc func tick() {
            guard let owner else { return }
            guard owner.window?.isVisible == true, !owner.isHiddenOrHasHiddenAncestor else {
                owner.settleMotion()
                return
            }
            owner.tickMotion(at: CACurrentMediaTime())
        }
    }

    private struct Drag {
        let id: String
        let origin: CGPoint
        var targetRegion: NSRect?
        var awaitingOrder: [String]?
    }
    private var dragging: Drag?
    private var cancelledDrag: String?
    /// Escape is consumed only while this container owns a pane gesture.
    var isDraggingPane: Bool { dragging != nil }

    override var isFlipped: Bool { true }

    /// Observe live preferences once for the cached card hierarchy.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearanceObserver = NotificationCenter.default.addObserver(forName: Config.didReload, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadAppearance()
            }
        }
    }

    /// Refresh cached surfaces too, so a hidden tab inherits current materials.
    func reloadAppearance() {
        if !Config.current.showPaneHeaders { cancelPaneDrag() }
        for card in cachedCards.values { card.reloadAppearance() }
        transitionShell?.needsDisplay = true
        if reduceMotion { settleMotion() }
        needsLayout = true
    }

    /// Visible live card rectangles in container coordinates. Overflow is excluded
    /// during chrome motion; filler belongs to `surfaceRects`, never to a grid.
    var liveSurfaceRects: [NSRect] {
        paneIDs.compactMap { id in
            guard let card = cards[id], !card.isHidden, card.alphaValue > 0.01 else { return nil }
            let rect = card.visibleSurfaceRect
            return rect.isEmpty || rect.isNull ? nil : rect
        }
    }

    /// Rounded occluding surfaces, including the temporary background envelopes.
    /// Chrome masks and native hit testing must follow these same rectangles.
    var surfaceRects: [NSRect] { transitionShell?.rects ?? liveSurfaceRects }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        motionDisplayLink?.invalidate()
        for terminals in resizeHolds.values { terminals.forEach { $0.endResizeHold() } }
    }

    /// Stop the old display's clock on every window move. Removal settles pane
    /// motion; external resize owners still release their own tokens.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        motionDisplayLink?.invalidate()
        motionDisplayLink = nil
        if window == nil {
            cancelPaneDrag()
            setLayoutTransitionActive(false)
            needsLayout = true
            layoutSubtreeIfNeeded()
            settleMotion()
        } else {
            startMotionClock()
        }
    }

    /// Unread state may change without a new server snapshot or a layout change.
    func updateAgentCompletions(_ unread: Set<String>) {
        for (id, card) in cards {
            card.setAgentCompletion(paneIDs.count > 1 && unread.contains(id))
        }
    }

    /// Refresh headers without discarding pending animation or optimistic
    /// geometry. A different tab/terminal identity cancels its previous drag.
    func show(_ tab: Wire.TabInfo?, focused: String?, zoomed: String?,
              completedAgentPanes: Set<String> = [], view: (String) -> TerminalView) {
        let wanted = tab?.panes.map(\.id) ?? []
        let terminals = Dictionary(uniqueKeysWithValues: wanted.map { ($0, view($0)) })
        let sameTab = self.tab?.id == tab?.id && wanted.contains { id in
            cards[id]?.terminal === terminals[id]
        }
        let geometryChanged = self.tab?.layout != tab?.layout || self.zoomed != zoomed
        if !sameTab {
            cancelPaneDrag()
            settleMotion()
            // Uncommitted divider feedback belongs to the abandoned gesture.
            draggedWeights = draggedWeights.filter { !$0.value.dragging }
            for card in cards.values { card.setTransitionClip(nil); card.releaseActions(); card.removeFromSuperview() }
            cards.removeAll()
            animateNextLayout = false
        } else if let drag = dragging, zoomed != nil || !wanted.contains(drag.id) {
            cancelPaneDrag()
        }
        if let order = dragging?.awaitingOrder, order != tab?.layout.panes {
            dragging?.awaitingOrder = nil
        }
        for (id, card) in cards where !wanted.contains(id) || card.terminal !== terminals[id] {
            cards[id] = nil
            appearing.remove(id)
            cachedCards[ObjectIdentifier(card.terminal)] = nil
            card.acceptsPaneInput = false
            card.releaseActions()
            // Remove immediately: a stale terminal must never cover its
            // expanding, interactive neighbor.
            card.removeFromSuperview()
            motion.removeAll { $0.card === card }
        }
        self.tab = tab
        self.zoomed = zoomed
        for pane in tab?.panes ?? [] {
            guard let terminal = terminals[pane.id] else { continue }
            let key = ObjectIdentifier(terminal)
            let card = cards[pane.id] ?? cachedCards[key] ?? PaneCard(terminal: terminal)
            let added = cards[pane.id] == nil
            cards[pane.id] = card
            cachedCards[key] = card
            for token in Array(resizeHolds.keys) where resizeHolds[token]?.contains(where: { $0 === terminal }) == false {
                terminal.beginResizeHold()
                resizeHolds[token]?.append(terminal)
            }
            card.update(pane: pane, focused: pane.id == focused, zoomed: zoomed == pane.id,
                        alone: wanted.count == 1, actions: actions)
            card.setAgentCompletion(wanted.count > 1 && completedAgentPanes.contains(pane.id))
            card.acceptsPaneInput = zoomed == nil || zoomed == pane.id
            card.allowsPointerFocus = !layoutTransitionActive
            if card.superview !== self { addSubview(card) }
            if added {
                card.isHidden = false
                // Always opaque: a translucent card shows the glass behind it,
                // which reads as a flash, so new panes move into place instead.
                card.alphaValue = 1
                if sameTab { appearing.insert(pane.id) }
            }
        }
        paneIDs = wanted
        if let layout = tab?.layout { reconcileWeights(layout) }
        animateNextLayout = animateNextLayout || (sameTab && geometryChanged)
        needsLayout = true
    }

    /// Call with existing live views from ALL workspaces after state pruning
    /// and workspace removal; do not create views just to populate this list.
    /// Closed cards leave immediately and cannot remain cached afterward.
    func prunePaneCards(keeping terminals: [TerminalView]) {
        let live = Set(terminals.map(ObjectIdentifier.init))
        cachedCards = cachedCards.filter { live.contains($0.key) }
        draggedWeights = draggedWeights.filter { $0.key.terminals.allSatisfy(live.contains) }
    }

    /// Bracket external chrome motion. Supply the final container size to seat
    /// live grids once, then animate the container shell without a resize hold.
    /// Interactive resizing can still acquire its own explicit hold separately.
    func setLayoutTransitionActive(_ active: Bool, finalSize: NSSize? = nil) {
        guard active != layoutTransitionActive || (active && finalSize != layoutTransitionSize) else { return }
        cancelPaneDrag()
        layoutTransitionActive = active
        layoutTransitionSize = active ? finalSize : nil
        if active { settleMotion() }
        if active && finalSize != nil {
            if transitionShell == nil {
                let shell = PaneTransitionShell(frame: bounds)
                addSubview(shell, positioned: .below, relativeTo: subviews.first)
                transitionShell = shell
            }
        } else {
            transitionShell?.removeFromSuperview()
            transitionShell = nil
        }
        for card in cards.values {
            card.allowsPointerFocus = !active
            if transitionShell == nil { card.setTransitionClip(nil) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var rects: [String: NSRect] = [:]
        var dividerSlots: [DividerSlot] = []
        let layoutBounds = NSRect(origin: bounds.origin, size: layoutTransitionSize ?? bounds.size)
        if let tab { slots(tab.layout, in: layoutBounds, panes: &rects, dividers: &dividerSlots) }
        var envelopes: [String: NSRect] = [:]
        if let shell = transitionShell {
            var unused: [DividerSlot] = []
            if let tab { slots(tab.layout, in: bounds, panes: &envelopes, dividers: &unused) }
            if let zoomed { envelopes = [zoomed: bounds] }
            if shell.frame != bounds { shell.frame = bounds }
            shell.update(paneIDs.compactMap { envelopes[$0] })
        }
        slotFrames = rects
        updateDividers(zoomed == nil ? dividerSlots : [])
        var targets: [Motion] = []
        for id in paneIDs {
            guard let card = cards[id], let slot = rects[id], dragging?.id != id else { continue }
            let hidden = zoomed != nil && zoomed != id
            var target = zoomed == id ? layoutBounds : slot
            if let envelope = envelopes[id] {
                // Final grids move with their own envelope. Right placement
                // mirrors the leading-edge anchor without scaling any glyphs.
                target.origin.x = Config.current.tabs.isRight ? envelope.maxX - target.width : envelope.minX
                target.origin.y = envelope.minY
                card.setTransitionClip(envelope.offsetBy(dx: -target.minX, dy: -target.minY))
            } else {
                card.setTransitionClip(nil)
            }
            // Resize once, before the reveal. No scaled glyphs, stale held grid,
            // or per-tick terminal layout is involved in the transition.
            let entry = appearing.contains(id) ? entryOffset(for: id) : nil
            let start = NSRect(origin: entry.map { NSPoint(x: target.minX + $0.x, y: target.minY + $0.y) } ?? card.frame.origin,
                               size: target.size)
            if !hidden && card.isHidden { card.isHidden = false }
            targets.append(Motion(card: card, from: start, to: target,
                                  fromAlpha: card.alphaValue, toAlpha: hidden ? 0 : 1, hide: hidden))
        }
        let shouldAnimate = animateNextLayout || !motion.isEmpty
        animateNextLayout = false
        appearing.removeAll()
        // Header/focus updates leave an in-flight transition's clock intact.
        let unchanged = targets.count == motion.count && targets.allSatisfy { target in
            motion.contains { $0.card === target.card && $0.to == target.to && $0.toAlpha == target.toAlpha && $0.hide == target.hide }
        }
        if unchanged && !motion.isEmpty && !layoutTransitionActive && !reduceMotion { return }
        startMotion(targets, animated: shouldAnimate && !layoutTransitionActive && !reduceMotion)
    }

    private var reduceMotion: Bool { Config.current.motion == .off || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where a new pane's card begins: a few points toward the pane it was
    /// split from, so it slides out from the divider into place.
    private func entryOffset(for id: String) -> NSPoint {
        guard let tab, let (direction, index) = splitPosition(of: id, in: tab.layout) else { return .zero }
        let distance: CGFloat = index > 0 ? -12 : 12
        return direction == .right ? NSPoint(x: distance, y: 0) : NSPoint(x: 0, y: distance)
    }

    private func splitPosition(of id: String, in node: Wire.LayoutNode) -> (Wire.Direction, Int)? {
        guard case .split(let split) = node else { return nil }
        for (index, child) in split.children.enumerated() {
            if case .pane(let pane) = child.layout, pane == id { return (split.direction, index) }
            if let found = splitPosition(of: id, in: child.layout) { return found }
        }
        return nil
    }

    /// Collect logical slots once for layout, stable drag targeting and reusable
    /// divider geometry. The last child absorbs rounding at the far edge.
    private func slots(_ node: Wire.LayoutNode, in rect: NSRect, panes: inout [String: NSRect], dividers: inout [DividerSlot]) {
        switch node {
        case .pane(let id): panes[id] = rect
        case .split(let split):
            let n = split.children.count
            guard n > 0 else { return }
            let right = split.direction == .right
            let weights = draggedWeights[splitKey(split)]?.weights ?? split.children.map(\.weight)
            let total = max(weights.reduce(0, +), 0.0001)
            let length = max(0, (right ? rect.width : rect.height) - Self.gap * CGFloat(n - 1))
            var offset = right ? rect.minX : rect.minY
            var children: [NSRect] = []
            for (i, child) in split.children.enumerated() {
                let end = right ? rect.maxX : rect.maxY
                let span = max(0, i == n - 1 ? end - offset : (length * CGFloat(weights[i] / total)).rounded())
                let r = right ? NSRect(x: offset, y: rect.minY, width: span, height: rect.height)
                              : NSRect(x: rect.minX, y: offset, width: rect.width, height: span)
                children.append(r)
                slots(child.layout, in: r, panes: &panes, dividers: &dividers)
                offset += span + Self.gap
            }
            for i in 0..<max(n - 1, 0) {
                let a = children[i], b = children[i + 1]
                let gap = right ? NSRect(x: a.maxX, y: rect.minY, width: Self.gap, height: rect.height)
                                : NSRect(x: rect.minX, y: a.maxY, width: rect.width, height: Self.gap)
                let pair = right ? NSRect(x: a.minX, y: rect.minY, width: b.maxX - a.minX, height: rect.height)
                                 : NSRect(x: rect.minX, y: a.minY, width: rect.width, height: b.maxY - a.minY)
                dividers.append(DividerSlot(key: DividerKey(split: split.id, index: i), split: splitKey(split),
                    direction: split.direction, frame: gap.insetBy(dx: right ? -2 : 0, dy: right ? 0 : -2), within: pair))
            }
        }
    }

    /// Reuse divider views through frame/metadata changes; ignore stale drag
    /// callbacks after a tab or split's child membership changes.
    private func updateDividers(_ slots: [DividerSlot]) {
        let wanted = Set(slots.map(\.key))
        for (key, divider) in dividers where !wanted.contains(key) {
            divider.removeFromSuperview()
            dividers[key] = nil
        }
        for slot in slots {
            let divider = dividers[slot.key] ?? DividerView(frame: .zero)
            divider.update(direction: slot.direction, within: slot.within) { [weak self] ratio, done in
                guard let self, let split = self.findSplit(slot.key.split), self.splitKey(split) == slot.split else { return }
                self.resizeDivider(split: split.id, index: slot.key.index, ratio: ratio, done: done)
            }
            if divider.frame != slot.frame { divider.frame = slot.frame }
            // Invisible/overlapping dividers must not intercept motion or a drag.
            let hidden = !motion.isEmpty || animateNextLayout || dragging != nil || layoutTransitionActive
            if divider.isHidden != hidden { divider.isHidden = hidden }
            if divider.superview !== self { addSubview(divider) }
            dividers[slot.key] = divider
        }
    }

    /// A divider's identity includes its terminals, preventing collisions across
    /// workspaces whose server-side split IDs happen to be the same.
    private func splitKey(_ split: Wire.LayoutNode.Split) -> SplitKey {
        SplitKey(id: split.id, terminals: split.children.flatMap { $0.layout.panes }.sorted().compactMap {
            cards[$0].map { ObjectIdentifier($0.terminal) }
        })
    }

    /// Find the current server split rather than capturing stale weights in a
    /// divider callback that can outlive several metadata/layout updates.
    private func findSplit(_ id: String) -> Wire.LayoutNode.Split? {
        func find(_ node: Wire.LayoutNode) -> Wire.LayoutNode.Split? {
            guard case .split(let split) = node else { return nil }
            if split.id == id { return split }
            return split.children.lazy.compactMap { find($0.layout) }.first
        }
        return tab.flatMap { find($0.layout) }
    }

    /// Apply local divider feedback immediately and retain it until a matching
    /// server echo, including when unrelated pane metadata arrives mid-drag.
    func resizeDivider(split id: String, index: Int, ratio: Double, done: Bool) {
        guard let split = findSplit(id), index >= 0, index + 1 < split.children.count else { return }
        let key = splitKey(split)
        var pending = draggedWeights[key] ?? PendingWeights(children: split.children.map { $0.layout.panes.sorted() },
            weights: split.children.map(\.weight), dragging: true)
        let ratio = min(max(ratio, 0.05), 0.95)
        let pair = pending.weights[index] + pending.weights[index + 1]
        pending.weights[index] = pair * ratio
        pending.weights[index + 1] = pair * (1 - ratio)
        pending.dragging = !done
        draggedWeights[key] = pending
        needsLayout = true
        if done { actions?.resize(id, index, ratio) }
    }

    /// Retire confirmed weights only after mouse-up; a coincidentally matching
    /// intermediate echo cannot erase the active divider drag's state.
    private func reconcileWeights(_ node: Wire.LayoutNode) {
        guard case .split(let split) = node else { return }
        let key = splitKey(split)
        if let pending = draggedWeights[key] {
            let weights = split.children.map(\.weight)
            let total = max(weights.reduce(0, +), 0.0001)
            let localTotal = max(pending.weights.reduce(0, +), 0.0001)
            let confirmed = zip(weights, pending.weights).allSatisfy { abs($0 / total - $1 / localTotal) < 0.00001 }
            if pending.children != split.children.map({ $0.layout.panes.sorted() }) || (!pending.dragging && confirmed) {
                draggedWeights[key] = nil
            }
        }
        split.children.forEach { reconcileWeights($0.layout) }
    }

    /// Retarget from visible position/opacity, retaining a bounded deadline for
    /// the interrupted sequence. Pane motion never acquires a terminal hold.
    private func startMotion(_ targets: [Motion], animated: Bool) {
        motion = targets
        let moving = targets.contains { $0.from != $0.to || $0.fromAlpha != $0.toAlpha }
        guard animated && moving else { settleMotion(); return }
        let now = CACurrentMediaTime()
        let duration: TimeInterval = Config.current.motion == .snappy ? 0.18 : 0.26
        if motionDeadline == nil { motionDeadline = now + duration }
        motionStarted = now
        motionDuration = min(duration, max(0, (motionDeadline ?? now) - now))
        guard motionDuration > 0 else { settleMotion(); return }
        applyMotion(0)
        startMotionClock()
    }

    /// Pace visible motion to this view's display. Headless layouts acquire no
    /// clock and can use tickMotion(at:) directly; attaching starts that clock.
    private func startMotionClock() {
        guard motionDisplayLink == nil, !motion.isEmpty, let window else { return }
        guard window.isVisible, !isHiddenOrHasHiddenAncestor else { settleMotion(); return }
        let link = displayLink(target: MotionTarget(self), selector: #selector(MotionTarget.tick))
        link.add(to: .main, forMode: .common)
        motionDisplayLink = link
    }

    /// Advance the shared clock using monotonic media time. Tests can drive
    /// this same path without waiting for a run loop or sending screen input.
    func tickMotion(at time: TimeInterval) {
        guard !motion.isEmpty else { settleMotion(); return }
        let progress = reduceMotion ? 1 : min(1, max(0, (time - motionStarted) / motionDuration))
        if progress >= 1 { settleMotion() }
        else { applyMotion(CGFloat(1 - pow(1 - progress, 3))) }
    }

    /// Write position/opacity only after seating the final size on the first
    /// frame. Core Animation never scales terminal glyphs or adds implicit motion.
    private func applyMotion(_ progress: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in motion where item.card !== cards[dragging?.id ?? ""] {
            let a = item.from, b = item.to
            let frame = NSRect(x: a.minX + (b.minX - a.minX) * progress,
                y: a.minY + (b.minY - a.minY) * progress,
                width: b.width, height: b.height)
            if item.card.frame.size != frame.size {
                item.card.frame = frame
                item.card.updateTransitionMaskBounds()
                // Only a new target seats a live grid; subsequent ticks move
                // the wrapper's origin without invoking its size setter.
                item.card.layoutSubtreeIfNeeded()
            } else if item.card.frame.origin != frame.origin {
                item.card.setFrameOrigin(frame.origin)
            }
            let alpha = item.fromAlpha + (item.toAlpha - item.fromAlpha) * progress
            if item.card.alphaValue != alpha { item.card.alphaValue = alpha }
        }
        CATransaction.commit()
        onSurfaceLayout?()
    }

    /// Complete this clock and restore dividers; external resize owners keep
    /// their holds. There are no retired terminal overlays to release.
    private func settleMotion() {
        motionDisplayLink?.invalidate()
        motionDisplayLink = nil
        applyMotion(1)
        for item in motion where item.card.isHidden != item.hide { item.card.isHidden = item.hide }
        motion.removeAll()
        motionDeadline = nil
        let hidden = dragging != nil || layoutTransitionActive
        for divider in dividers.values where divider.isHidden != hidden { divider.isHidden = hidden }
    }

    /// Lift one visible card and keep its frame tied directly to translation.
    /// Reorder uses logical slots, with an inset entry and expanded exit region,
    /// so moving survivors and jitter at a shared boundary cannot swap it back.
    func paneDragChanged(_ id: String, _ translation: CGSize) {
        guard cancelledDrag != id, let card = cards[id], card.acceptsPaneInput, !card.isHidden, !layoutTransitionActive else { return }
        if dragging?.id != id {
            cancelPaneDrag()
            dragging = Drag(id: id, origin: card.frame.origin)
            motion.removeAll { $0.card === card }
            card.layer?.zPosition = 100
            card.alphaValue = 0.85
            dividers.values.forEach { $0.isHidden = true }
        }
        NSCursor.closedHand.set()
        guard let origin = dragging?.origin else { return }
        let position = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
        if card.frame.origin != position { card.setFrameOrigin(position) }
        let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? CGPoint(x: card.frame.midX, y: card.frame.midY)
        if let region = dragging?.targetRegion, region.insetBy(dx: -12, dy: -12).contains(point) { return }
        dragging?.targetRegion = nil
        guard dragging?.awaitingOrder == nil else { return }
        for target in paneIDs where target != id {
            guard let other = cards[target], other.acceptsPaneInput, !other.isHidden,
                  let slot = slotFrames[target] else { continue }
            let inner = slot.insetBy(dx: min(12, slot.width * 0.15), dy: min(12, slot.height * 0.15))
            if inner.contains(point) {
                dragging?.targetRegion = slot
                dragging?.awaitingOrder = tab?.layout.panes
                actions?.swap(id, target)
                break
            }
        }
    }

    /// Release settles smoothly into the committed slot. A stale gesture from
    /// a tab that was hidden cannot release a new tab's drag.
    func paneDragEnded(_ id: String, _ translation: CGSize) {
        if cancelledDrag == id { cancelledDrag = nil }
        guard dragging?.id == id else { return }
        cancelPaneDrag()
    }

    /// Use for interrupted gestures, zoom, sidebar movement and tab switches;
    /// always restore lift/opacity before the wrapper is reused. Explicit
    /// cancellation ignores the rest of that physical drag until mouse-up.
    func cancelPaneDrag(untilRelease: Bool = false) {
        if !untilRelease { cancelledDrag = nil }
        guard let drag = dragging else { return }
        if untilRelease { cancelledDrag = drag.id }
        cards[drag.id]?.layer?.zPosition = 0
        cards[drag.id]?.alphaValue = 1
        dragging = nil
        NSCursor.arrow.set()
        animateNextLayout = true
        needsLayout = true
    }

    /// Own a resize hold across tab changes and newly shown panes. Another
    /// transition cannot release it, including after its original tab is hidden.
    func beginResizeHold() -> UUID {
        let token = UUID()
        let terminals = cards.values.map(\.terminal)
        resizeHolds[token] = terminals
        terminals.forEach { $0.beginResizeHold() }
        return token
    }

    /// Release only the terminals acquired by this owner, including hidden ones.
    func endResizeHold(_ token: UUID) {
        resizeHolds.removeValue(forKey: token)?.forEach { $0.endResizeHold() }
    }

    /// The visible logical slot nearest the focused pane in a direction.
    func pane(from focused: String, toward direction: Direction) -> String? {
        guard let from = slotFrames[focused], cards[focused]?.acceptsPaneInput == true else { return nil }
        let center = NSPoint(x: from.midX, y: from.midY)
        var best: (id: String, distance: CGFloat)?
        for id in paneIDs where id != focused && cards[id]?.acceptsPaneInput == true {
            guard let f = slotFrames[id] else { continue }
            let ahead: Bool
            let distance: CGFloat
            switch direction {
            case .left: ahead = f.maxX <= from.minX + 1; distance = from.minX - f.maxX + abs(f.midY - center.y) * 0.25
            case .right: ahead = f.minX >= from.maxX - 1; distance = f.minX - from.maxX + abs(f.midY - center.y) * 0.25
            case .up: ahead = f.maxY <= from.minY + 1; distance = from.minY - f.maxY + abs(f.midX - center.x) * 0.25
            case .down: ahead = f.minY >= from.maxY - 1; distance = f.minY - from.maxY + abs(f.midX - center.x) * 0.25
            }
            if ahead, best == nil || distance < best!.distance { best = (id, distance) }
        }
        return best?.id
    }

    enum Direction { case left, right, up, down }
}

/// One ephemeral background for all moving pane envelopes. It fills the band
/// outside final live grids, preserves split gaps, and absorbs filler clicks.
/// The existing window clock owns its lifetime; it stores no terminal pixels.
@MainActor private final class PaneTransitionShell: NSView {
    private(set) var rects: [NSRect] = []
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Retarget without replacing the shell, including direction reversals.
    func update(_ rects: [NSRect]) {
        guard self.rects != rects else { return }
        self.rects = rects
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        for rect in rects {
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(roundedRect: rect, xRadius: AppDelegate.paneCornerRadius, yRadius: AppDelegate.paneCornerRadius)
            path.addClip()
            NSColor(Theme.current.backgroundColor).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.08).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return !isHiddenOrHasHiddenAncestor && rects.contains { rect in
            CGPath(roundedRect: rect, cornerWidth: AppDelegate.paneCornerRadius,
                cornerHeight: AppDelegate.paneCornerRadius, transform: nil).contains(local)
        } ? self : nil
    }

    override func resetCursorRects() {
        for rect in rects { addCursorRect(rect, cursor: .arrow) }
    }

    // A blank band is not a terminal cell or a control beneath the pane.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// A stable gap view. Its event loop freezes the pair geometry for one drag,
/// while normal layouts update the view in place instead of reconstructing it.
@MainActor private final class DividerView: NSView {
    private var direction = Wire.Direction.right
    private var within = NSRect.zero
    private var onDrag: ((Double, Bool) -> Void)?

    /// Refresh the next drag's geometry and callback without replacing the view.
    func update(direction: Wire.Direction, within: NSRect, onDrag: @escaping (Double, Bool) -> Void) {
        if self.direction != direction { window?.invalidateCursorRects(for: self) }
        self.direction = direction
        self.within = within
        self.onDrag = onDrag
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: direction == .right ? .resizeLeftRight : .resizeUpDown)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let onDrag else { return }
        if event.clickCount == 2 { onDrag(0.5, true); return }
        guard let window, let container = superview else { return }
        let within = self.within, direction = self.direction
        var lastRatio: Double?
        var finished = false
        defer { if !finished, let lastRatio { onDrag(lastRatio, true) } }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard superview === container, !isHidden else { break }
            let done = event.type == .leftMouseUp
            let p = container.convert(event.locationInWindow, from: nil)
            let gap = SplitContainerView.gap
            let ratio = direction == .right
                ? (p.x - within.minX - gap / 2) / max(within.width - gap, 1)
                : (p.y - within.minY - gap / 2) / max(within.height - gap, 1)
            let clamped = min(max(Double(ratio), 0.05), 0.95)
            lastRatio = clamped
            finished = done
            onDrag(clamped, done)
            if done { break }
        }
    }
}

/// One pane's card: the frosted card of the window's design, a header, and
/// the terminal.
@MainActor
final class PaneCard: NSVisualEffectView {
    let terminal: TerminalView
    /// Zoomed-out panes remain drawable during their fade but cannot receive input.
    var acceptsPaneInput = true
    var allowsPointerFocus = true
    private var transitionClip: NSRect?
    private let transitionMask = CAShapeLayer()
    private let viewport = NSClipView()
    private let content = PaneContentView()

    /// The live portion of this card, in its parent's coordinates.
    var visibleSurfaceRect: NSRect {
        let visible = transitionClip.map { bounds.intersection($0) } ?? bounds
        return visible.offsetBy(dx: frame.minX, dy: frame.minY)
    }
    private let header: NSHostingView<PaneHeader>
    private let model = PaneHeaderModel()
    private var headerSize: NSLayoutConstraint!
    static var headerHeight: CGFloat { Config.current.compactPanes ? 32 : 42 }

    init(terminal: TerminalView) {
        self.terminal = terminal
        header = NSHostingView(rootView: PaneHeader(model: model))
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = AppDelegate.paneCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        // Near the window's top, the title bar's safe area would push the
        // header's content down; the card places its own content.
        header.safeAreaRegions = []
        // A native viewport clips descendants' drawing and tracking together.
        // Its document keeps the destination size through every shell frame.
        viewport.drawsBackground = false
        viewport.documentView = content
        addSubview(viewport)
        content.addSubview(header)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        // Native tracking must also stop at the terminal's own edges, rather
        // than extending into the header on AppKit's unclipped-view default.
        terminal.clipsToBounds = true
        content.addSubview(terminal)
        headerSize = header.heightAnchor.constraint(equalToConstant: Self.headerHeight)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            headerSize,
            terminal.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminal.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        updateTransitionMaskBounds()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsPaneInput else { return nil }
        let local = convert(point, from: superview)
        if let clip = transitionClip, !CGPath(roundedRect: clip, cornerWidth: AppDelegate.paneCornerRadius,
            cornerHeight: AppDelegate.paneCornerRadius, transform: nil).contains(local) { return nil }
        return super.hitTest(point)
    }

    /// Clip only presentation overflow. The live grid keeps its destination
    /// bounds, while shell drawing and hit testing retain the moving perimeter.
    func setTransitionClip(_ rect: NSRect?) {
        guard transitionClip != rect else { return }
        let wasClipped = transitionClip != nil
        transitionClip = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect {
            transitionMask.frame = bounds
            transitionMask.path = CGPath(roundedRect: rect, cornerWidth: AppDelegate.paneCornerRadius,
                cornerHeight: AppDelegate.paneCornerRadius, transform: nil)
            transitionMask.fillColor = NSColor.black.cgColor
            layer?.mask = transitionMask
            layer?.cornerRadius = 0
        } else {
            if layer?.mask === transitionMask { layer?.mask = nil }
            layer?.cornerRadius = AppDelegate.paneCornerRadius
        }
        if !wasClipped || rect == nil { reloadAppearance() }
        updateTransitionMaskBounds()
        CATransaction.commit()
    }

    /// Keep the native clipping viewport and rounded mask in the same card
    /// coordinates. Only a new destination resizes the document/live grid.
    func updateTransitionMaskBounds() {
        if transitionClip != nil { transitionMask.frame = bounds }
        if content.frame.size != bounds.size {
            content.setFrameSize(bounds.size)
            content.needsLayout = true
        }
        let visible = transitionClip.map { bounds.intersection($0) } ?? bounds
        let rect = visible.isNull ? NSRect.zero : visible
        if viewport.frame != rect { viewport.frame = rect }
        if viewport.bounds.origin != rect.origin { viewport.scroll(to: rect.origin) }
        window?.invalidateCursorRects(for: self)
        window?.invalidateCursorRects(for: terminal)
        terminal.updateTrackingAreas()
    }

    /// Detached cached cards must not keep an old workspace's actions alive.
    func releaseActions() {
        model.actions = nil
        layer?.zPosition = 0
    }

    func setAgentCompletion(_ unread: Bool) {
        if model.hasAgentCompletion != unread { model.hasAgentCompletion = unread }
    }

    /// Update header metadata without replacing its hosting view or terminal.
    /// Every server update passes through here, so only real changes reach the
    /// observable model and the card's surfaces.
    func update(pane: Wire.PaneInfo, focused: Bool, zoomed: Bool, alone: Bool, actions: SplitContainerView.Actions?) {
        if model.pane != pane { model.pane = pane }
        if model.focused != focused { model.focused = focused }
        if model.zoomed != zoomed { model.zoomed = zoomed }
        if model.alone != alone { model.alone = alone }
        model.actions = actions
        reloadAppearance()
    }

    /// Apply live pane preferences without rebuilding the card or terminal.
    /// Assignments are skipped when nothing changed: re-setting a vibrancy
    /// material or layer property makes AppKit refresh the frost, which in a
    /// window behind another shows as a flicker along the card's edge on
    /// every title or status update.
    func reloadAppearance() {
        if model.height != Self.headerHeight { model.height = Self.headerHeight }
        let motionDisabled = Config.current.motion == .off
        if model.motionDisabled != motionDisabled { model.motionDisabled = motionDisabled }
        let showsHeader = Config.current.showPaneHeaders
        if header.isHidden == showsHeader { header.isHidden = !showsHeader }
        let headerHeight = showsHeader ? Self.headerHeight : 0
        if headerSize.constant != headerHeight {
            headerSize.constant = headerHeight
            needsLayout = true
        }
        let solid = Config.current.solidSurfaces
        let material: NSVisualEffectView.Material = solid ? .windowBackground : .hudWindow
        if self.material != material { self.material = material }
        let blending: NSVisualEffectView.BlendingMode = solid ? .withinWindow : .behindWindow
        if blendingMode != blending { blendingMode = blending }
        let state: NSVisualEffectView.State = solid ? .inactive : .active
        if self.state != state { self.state = state }
        let background = solid ? NSColor(Theme.current.backgroundColor).cgColor : NSColor.clear.cgColor
        if layer?.backgroundColor != background { layer?.backgroundColor = background }
        let border: CGFloat = transitionClip != nil ? 0 : 0.5
        if layer?.borderWidth != border { layer?.borderWidth = border }
        let alpha: CGFloat = !model.focused && Config.current.fadeInactivePanes ? 0.72 : 1
        if terminal.alphaValue != alpha { terminal.alphaValue = alpha }
    }

    /// Track the entire card, including terminals and configurations without a
    /// header. Never focus through a popup, drag, or a hidden/noninteractive card.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard Config.current.focusFollowsMouse, allowsPointerFocus, acceptsPaneInput, !isHiddenOrHasHiddenAncestor,
              window?.isKeyWindow == true, window?.hasKoiPopup != true,
              NSEvent.pressedMouseButtons == 0, !model.focused, let pane = model.pane else { return }
        model.actions?.focus(pane.id)
    }
}

/// The destination-sized document inside a pane's native clipping viewport.
/// Children use fixed document bounds, not the changing visible envelope.
@MainActor private final class PaneContentView: NSView {
    override var isFlipped: Bool { true }
}

/// Header metadata and intents for the card's stable SwiftUI hosting view.
@MainActor @Observable
final class PaneHeaderModel {
    var pane: Wire.PaneInfo?
    var focused = false
    var zoomed = false
    var height = PaneCard.headerHeight
    var motionDisabled = Config.current.motion == .off
    /// The only pane of its tab: there is nothing for Zoom to expand into.
    var alone = false
    var hasAgentCompletion = false
    @ObservationIgnored var actions: SplitContainerView.Actions?
}

/// A pane's header: the program's mark, its title or its
/// name and directory, and, when the pane is focused, split right, split
/// down, zoom and close. Zoom is only useful when the tab has split panes.
struct PaneHeader: View {
    let model: PaneHeaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var headerDragging = false
    /// The pointer's x in the header, and the header's width, for the centered
    /// drag handle and its grab cursor.
    @State private var hoverX: CGFloat?
    @State private var headerWidth: CGFloat = 1

    var body: some View {
        let pane = model.pane
        let style = Programs.style(for: pane)
        let label = TabLabel.make(pane, style)
        HStack(spacing: 8) {
            // Every pane shows its mark and name, sized and centred to sit on
            // the same line as the sidebar toggle and New Tab (see headerHeight).
            ProgramMark(style: style)
                .frame(width: 18, height: 18)
                .overlay(alignment: .topTrailing) {
                    if model.hasAgentCompletion {
                        AgentCompletionDot().offset(x: 2, y: -2)
                    }
                }
                .accessibilityValue(model.hasAgentCompletion ? "Agent finished" : "")
            HStack(spacing: 6) {
                // The directory gives way before the name does.
                Text(label.title).foregroundStyle(.primary).layoutPriority(1)
                if !label.detail.isEmpty {
                    Text(label.detail).foregroundStyle(.tertiary).truncationMode(.head)
                }
            }
            .font(.system(size: 13.5, weight: .medium))
            .lineLimit(1)
            Spacer(minLength: 8)
            // Reserve the controls' slot so focus changes do not reflow the
            // title or move the drag handle. Unfocused buttons have no hover
            // anchors or input handlers, only their reserved layout space.
            HStack(spacing: 2) {
                if model.focused {
                    IconButton(symbol: "rectangle.split.2x1", help: "Split Right", shortcut: .newSplit, glyphSize: 12.5, controlSize: 24) { model.actions?.split(.right) }
                    IconButton(symbol: "rectangle.split.1x2", help: "Split Down", shortcut: .newSplitDown, glyphSize: 12.5, controlSize: 24) { model.actions?.split(.down) }
                    if !model.alone {
                        IconButton(symbol: model.zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", help: model.zoomed ? "Unzoom Pane" : "Zoom Pane", shortcut: .toggleZoom, glyphSize: 12.5, controlSize: 24) { model.actions?.zoom() }
                    }
                    IconButton(symbol: "xmark", help: model.alone ? "The last pane stays open. Close its tab to end it." : "Close Pane", shortcut: model.alone ? nil : .closePane, glyphSize: 12.5, controlSize: 24) { model.actions?.close() }
                        .disabled(model.alone)
                        .opacity(model.alone ? 0.25 : 1)
                }
            }
            .frame(width: model.alone ? 76 : 102, height: 24, alignment: .trailing)
            .allowsHitTesting(model.focused)
            .accessibilityHidden(!model.focused)
        }
        .padding(.leading, 12)
        // Together with the card's 5 pt inset and 24 pt controls, this puts
        // the close button directly below the horizontal top bar's +.
        .padding(.trailing, 11)
        .frame(height: model.height)
        // The same dark tint over the card's frost as the terminal below.
        .background(Theme.current.backgroundColor.opacity(0.85))
        .contentShape(.rect)
        .onTapGesture { if let id = pane?.id { model.actions?.focus(id) } }
        // Drag the header to reorder the pane: the card lifts and follows the
        // cursor, swapping places with whatever pane it is over. Measured in
        // the window's space, not the header's own: the header moves with the
        // card as it is dragged, so a local translation would feed back on
        // itself and jitter.
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .updating($headerDragging) { _, dragging, _ in dragging = true }
                .onChanged { value in if let id = pane?.id { model.actions?.dragChanged(id, value.translation) } }
                .onEnded { value in if let id = pane?.id { model.actions?.dragEnded(id, value.translation) } }
        )
        .onChange(of: headerDragging) { wasDragging, isDragging in
            if wasDragging && !isDragging, let id = pane?.id { model.actions?.dragEnded(id, .zero) }
        }
        // Near the center, where the handle shows, the cursor becomes an open
        // hand so it reads as something to grab and drag.
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hoverX = p.x
                if abs(p.x - headerWidth / 2) < 42 { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            case .ended:
                hoverX = nil
                NSCursor.arrow.set()
            }
        }
        // A thin handle at the top-center, shown only near the middle, hinting
        // the header can be grabbed to drag the pane.
        .overlay(alignment: .top) {
            GeometryReader { geo in
                let near = hoverX.map { abs($0 - geo.size.width / 2) < 42 } ?? false
                SwiftUI.Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 26, height: 3)
                    .position(x: geo.size.width / 2, y: 4.5)
                    .opacity(near ? 1 : 0)
                    .animation(reduceMotion || model.motionDisabled ? nil : .easeOut(duration: 0.12), value: near)
                    .onAppear { headerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { headerWidth = $1 }
            }
            .allowsHitTesting(false)
        }
    }
}

/// A program's mark in one color: its logo as a template, a symbol, or for
/// a shell the bare prompt, `>_`.
struct ProgramMark: View {
    let style: ProgramStyle

    var body: some View {
        Group {
            switch style.mark ?? style.glyph {
            case .brand(let name):
                if let image = Programs.logo(name) {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                } else {
                    Text(">_")
                }
            case .symbol(let name):
                Image(systemName: name)
            case .text(let text):
                // The shell prompt (`>_`) reads cleaner at a medium weight;
                // single-letter marks (btop's B, htop's H) stay heavy. Sized
                // to fit the frame so it never truncates to an ellipsis.
                Text(text)
                    .font(.system(size: text.count > 1 ? 12 : 13, weight: text.count > 1 ? .semibold : .heavy, design: .monospaced))
                    .tracking(text.count > 1 ? -0.5 : -0.5)
                    .fixedSize()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary.opacity(0.85))
    }
}
