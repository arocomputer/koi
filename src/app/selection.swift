import CoreGraphics
import Foundation
import GhosttyVt

/// Turns mouse gestures into a terminal selection, using libghostty-vt's
/// selection gesture state machine: single press and drag select cells (by
/// pixel, not just by cell), double and triple click select words and lines
/// (and dragging after them extends by word or line), and dragging past the
/// top or bottom edge asks for the viewport to autoscroll.
///
/// One instance serves one terminal and holds it strongly, so the gesture's
/// tracked grid references are always freed before the terminal. Callers
/// drop and recreate the adapter whenever they replace the terminal. All
/// points are in surface pixels, origin top-left; the caller flips if its
/// view is bottom-up. Resulting selections are installed on the terminal
/// (which tracks them across output) for the renderer and copy to read.
@MainActor
final class TerminalSelection {
    /// The surface layout the pointer is interpreted against, in pixels:
    /// the whole surface, one cell, and the uniform inset around the grid.
    struct Geometry: Equatable {
        var size: CGSize
        var cell: CGSize
        var padding: CGFloat
    }

    let terminal: VTTerminal

    private var nativeGesture: GhosttySelectionGesture?
    private var events: [Int: GhosttySelectionGestureEvent] = [:]
    private var pressed = false
    private var lastPoint = CGPoint.zero

    init(terminal: VTTerminal) {
        self.terminal = terminal
    }

    isolated deinit {
        for event in events.values { ghostty_selection_gesture_event_free(event) }
        // The gesture releases its tracked refs through the terminal, which
        // this object still owns until after deinit.
        ghostty_selection_gesture_free(nativeGesture, terminal.raw)
    }

    /// Whether a button-down gesture is in progress (press without release
    /// or cancel).
    var isActive: Bool { pressed }

    /// Whether the pointer is past an edge and `autoscroll` should be called
    /// on a timer.
    var autoscrolling: Bool {
        guard pressed, let gesture = nativeGesture else { return false }
        var direction = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        ghostty_selection_gesture_get(gesture, terminal.raw, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &direction)
        return direction != GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
    }

    /// Starts a gesture. `time` is the event's monotonic timestamp and
    /// `repeatInterval` the double-click interval, which together decide
    /// whether this press continues a multi-click. A single press clears the
    /// old selection; a double or triple press selects the word or line.
    func press(at point: CGPoint, geometry: Geometry, time: TimeInterval, repeatInterval: TimeInterval) {
        guard geometry.isUsable, let gesture = ensureGesture(),
              let press = event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS),
              var ref = viewportRef(at: point, geometry: geometry) else { return }
        var position = GhosttySurfacePosition(x: point.x, y: point.y)
        var distance = Double(geometry.cell.width)
        var timeNs = Self.nanoseconds(time)
        var intervalNs = Self.nanoseconds(repeatInterval)
        guard ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &timeNs) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &intervalNs) == GHOSTTY_SUCCESS
        else { return }

        var selection = Self.emptySelection()
        let result = ghostty_selection_gesture_event(gesture, terminal.raw, press, &selection)
        guard result == GHOSTTY_SUCCESS || result == GHOSTTY_NO_VALUE else { return }
        pressed = true
        lastPoint = point
        if result == GHOSTTY_SUCCESS {
            install(selection)
        } else if clickCount == 1 {
            terminal.clearSelection()
        }
    }

    /// Extends the selection to the pointer while the button is down.
    func drag(at point: CGPoint, geometry: Geometry) {
        guard pressed, geometry.isUsable, let gesture = nativeGesture,
              let drag = event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG),
              var ref = viewportRef(at: point, geometry: geometry) else { return }
        var position = GhosttySurfacePosition(x: point.x, y: point.y)
        var native = geometry.native(columns: terminal.size.cols)
        guard ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &native) == GHOSTTY_SUCCESS
        else { return }
        lastPoint = point

        var selection = Self.emptySelection()
        let result = ghostty_selection_gesture_event(gesture, terminal.raw, drag, &selection)
        if result == GHOSTTY_SUCCESS {
            install(selection)
        } else if result == GHOSTTY_NO_VALUE {
            // Not yet a selection (inside the first cell's threshold).
            terminal.clearSelection()
        }
    }

    /// Ends the button-down phase and stops autoscrolling. A word or line
    /// selection stays; the click sequence is kept so a quick next press
    /// counts as a double or triple click.
    func release(at point: CGPoint, geometry: Geometry) {
        guard pressed, let gesture = nativeGesture,
              let release = event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) else { return }
        pressed = false
        // A release outside the surface maps to no cell.
        if geometry.isUsable, geometry.contains(point), var ref = viewportRef(at: point, geometry: geometry) {
            ghostty_selection_gesture_event_set(release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        } else {
            ghostty_selection_gesture_event_set(release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
        }
        ghostty_selection_gesture_event(gesture, terminal.raw, release, nil)
    }

    /// Abandons the gesture and its click sequence, leaving the selection
    /// as it is.
    func cancel() {
        pressed = false
        ghostty_selection_gesture_reset(nativeGesture, terminal.raw)
    }

    /// One autoscroll step: scrolls the viewport a row toward the pointer's
    /// edge and extends the selection to the pointer's new cell. Call on a
    /// timer (30–60 Hz) while `autoscrolling`; false means nothing was done
    /// and the timer can stop.
    @discardableResult
    func autoscroll(geometry: Geometry) -> Bool {
        guard autoscrolling, geometry.isUsable, let gesture = nativeGesture,
              let tick = event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK),
              var viewport = viewportCoordinate(at: lastPoint, geometry: geometry) else { return false }
        var position = GhosttySurfacePosition(x: lastPoint.x, y: lastPoint.y)
        var native = geometry.native(columns: terminal.size.cols)
        guard ghostty_selection_gesture_event_set(tick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(tick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_set(tick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &native) == GHOSTTY_SUCCESS
        else { return false }

        var selection = Self.emptySelection()
        let result = ghostty_selection_gesture_event(gesture, terminal.raw, tick, &selection)
        // The gesture resets itself when its anchor's screen went away.
        if clickCount == 0 { pressed = false }
        if result == GHOSTTY_SUCCESS { install(selection) }
        return pressed
    }

    // MARK: Native plumbing

    private var clickCount: UInt8 {
        guard let gesture = nativeGesture else { return 0 }
        var count: UInt8 = 0
        ghostty_selection_gesture_get(gesture, terminal.raw, GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &count)
        return count
    }

    /// The gesture, created on first press; nil if allocation fails, which
    /// leaves selection gestures inert rather than crashing.
    private func ensureGesture() -> GhosttySelectionGesture? {
        if nativeGesture == nil {
            var made: GhosttySelectionGesture?
            if ghostty_selection_gesture_new(nil, &made) == GHOSTTY_SUCCESS { nativeGesture = made }
        }
        return nativeGesture
    }

    /// The reusable event of a type, created on first use; nil if allocation
    /// fails.
    private func event(_ type: GhosttySelectionGestureEventType) -> GhosttySelectionGestureEvent? {
        let key = Int(type.rawValue)
        if let existing = events[key] { return existing }
        var made: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_event_new(nil, &made, type) == GHOSTTY_SUCCESS, let made else { return nil }
        events[key] = made
        return made
    }

    private static func emptySelection() -> GhosttySelection {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        return selection
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func install(_ selection: GhosttySelection) {
        var selection = selection
        ghostty_terminal_set(terminal.raw, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// The pointer's cell in the viewport, clamped to the grid so a drag
    /// outside the surface selects to its edge.
    private func viewportCoordinate(at point: CGPoint, geometry: Geometry) -> GhosttyPointCoordinate? {
        let size = terminal.size
        guard size.cols > 0, size.rows > 0 else { return nil }
        let col = ((point.x - geometry.padding) / geometry.cell.width).rounded(.down)
        let row = ((point.y - geometry.padding) / geometry.cell.height).rounded(.down)
        guard col.isFinite, row.isFinite else { return nil }
        return GhosttyPointCoordinate(
            x: UInt16(min(max(col, 0), Double(size.cols - 1))),
            y: UInt32(min(max(row, 0), Double(size.rows - 1))))
    }

    private func viewportRef(at point: CGPoint, geometry: Geometry) -> GhosttyGridRef? {
        guard let coordinate = viewportCoordinate(at: point, geometry: geometry) else { return nil }
        var grid = GhosttyPoint()
        grid.tag = GHOSTTY_POINT_TAG_VIEWPORT
        grid.value.coordinate = coordinate
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(terminal.raw, grid, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }
}

private extension TerminalSelection.Geometry {
    /// Positive sizes are required by the native geometry.
    var isUsable: Bool {
        size.width >= 1 && size.height >= 1 && cell.width >= 1 && cell.height >= 1
    }

    func contains(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < size.width && point.y < size.height
    }

    func native(columns: UInt16) -> GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(
            columns: UInt32(columns),
            cell_width: UInt32(cell.width.rounded()),
            padding_left: UInt32(max(0, padding.rounded())),
            screen_height: UInt32(size.height.rounded()))
    }
}
