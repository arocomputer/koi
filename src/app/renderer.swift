import Foundation
import GhosttyVt
import Metal
import QuartzCore
import simd

/// A polled view of this renderer's committed frames and live Metal allocations.
/// CPU time is elapsed assembly-through-commit time, including drawable waits.
/// GPU time is nil when the latest completion fails or lacks valid timestamps.
struct RenderDiagnosticsSnapshot: Sendable, Equatable {
    let device: String
    let drawableWidth: Int
    let drawableHeight: Int
    let framesSubmitted: Int
    let framesCompleted: Int
    let framesFailed: Int
    let pendingFrame: Bool
    let inFlight: Int
    let deferred: [String: Int]
    let lastCPUFrameMS: Double?
    let maxCPUFrameMS: Double?
    let lastGPUFrameMS: Double?
    let atlasBytes: Int
    let bufferBytes: Int
    let issues: [RenderDiagnosticIssue]
}

/// A bounded, sanitized issue; repeats keep their identity and latest timestamp.
struct RenderDiagnosticIssue: Sendable, Equatable, Identifiable {
    let id: UUID
    var timestamp: Date
    let message: String
    var count: Int
}

/// Small lock-protected accounting shared with Metal completion threads. Every
/// mutable field is under the lock; neither commands nor Renderer are retained.
final class RenderDiagnosticsStats: @unchecked Sendable {
    enum Deferral: String, Sendable {
        case inflight, noDrawable, zeroSize, buffer, commandBuffer, encoder
    }

    /// Identity prevents counting a resource again for each frame using it.
    struct Allocation: Sendable {
        let id: ObjectIdentifier
        let bytes: Int
    }

    /// A reset changes the generation, but outstanding flights still retire.
    struct Submission: Sendable {
        fileprivate let id: UInt64
        fileprivate let generation: UUID
    }

    private struct Flight {
        let atlas: Allocation?
        let buffer: Allocation?
    }

    private struct State {
        var generation = UUID()
        var flights: [UInt64: Flight] = [:]
        var nextSubmission: UInt64 = 0
        var framesSubmitted = 0
        var framesCompleted = 0
        var framesFailed = 0
        var deferred: [String: Int] = [:]
        var lastCPUFrameMS: Double?
        var maxCPUFrameMS: Double?
        var lastGPUFrameMS: Double?
        var issues: [RenderDiagnosticIssue] = []

        /// Keep the sixteen most recently seen distinct issues, oldest first.
        mutating func recordIssue(_ message: String) {
            if let index = issues.firstIndex(where: { $0.message == message }) {
                var issue = issues.remove(at: index)
                issue.count += 1
                issue.timestamp = Date()
                issues.append(issue)
            } else {
                if issues.count == 16 { issues.removeFirst() }
                issues.append(.init(id: UUID(), timestamp: Date(), message: message, count: 1))
            }
        }
    }

    private let lock = NSLock()
    private var state = State()

    /// Count only committed commands; call before commit can invoke completion.
    func submitted(atlas: Allocation? = nil, buffer: Allocation? = nil) -> Submission {
        lock.withLock {
            let submission = Submission(id: state.nextSubmission, generation: state.generation)
            state.nextSubmission &+= 1
            state.flights[submission.id] = Flight(atlas: atlas, buffer: buffer)
            state.framesSubmitted += 1
            return submission
        }
    }

    /// Record after commit returns, even if completion has already retired it.
    func recordCPUFrame(_ milliseconds: Double, for submission: Submission) {
        lock.withLock {
            guard submission.generation == state.generation,
                  milliseconds.isFinite, milliseconds >= 0 else { return }
            state.lastCPUFrameMS = milliseconds
            state.maxCPUFrameMS = max(state.maxCPUFrameMS ?? milliseconds, milliseconds)
        }
    }

    /// Always retire the flight, but only count completions in their own reset
    /// generation. Failures count GPU errors, independently of retry deferrals.
    func completed(_ submission: Submission, succeeded: Bool, error: NSError? = nil,
                   gpuStartTime: Double = 0, gpuEndTime: Double = 0) {
        lock.withLock {
            guard state.flights.removeValue(forKey: submission.id) != nil else { return }
            guard submission.generation == state.generation else { return }
            if succeeded {
                state.framesCompleted += 1
            } else {
                state.framesFailed += 1
                // Never copy error descriptions, userInfo, or arbitrary domains:
                // driver messages can contain application-provided strings.
                if let error {
                    let domain = error.domain == MTLCommandBufferErrorDomain
                        ? MTLCommandBufferErrorDomain : "unknown domain"
                    state.recordIssue("GPU command failed (\(domain), code \(error.code)).")
                } else {
                    state.recordIssue("GPU command failed (error details unavailable).")
                }
            }
            let milliseconds = (gpuEndTime - gpuStartTime) * 1000
            state.lastGPUFrameMS = succeeded && gpuStartTime.isFinite && gpuStartTime > 0
                && gpuEndTime.isFinite && gpuEndTime >= gpuStartTime && milliseconds.isFinite
                ? milliseconds : nil
        }
    }

    /// Retry causes are a fixed vocabulary; allocation/encoding trouble also
    /// produces a generic issue without terminal or driver-provided text.
    func deferFrame(_ reason: Deferral) {
        lock.withLock {
            state.deferred[reason.rawValue, default: 0] += 1
            switch reason {
            case .buffer: state.recordIssue("Metal buffer allocation unavailable.")
            case .commandBuffer: state.recordIssue("Metal command buffer unavailable.")
            case .encoder: state.recordIssue("Metal render encoder unavailable.")
            case .inflight, .noDrawable, .zeroSize: break
            }
        }
    }

    /// Overflow can recover by eviction; only the second attempt omits glyphs.
    func atlasOverflow(omittedGlyphs: Bool) {
        lock.withLock {
            state.recordIssue(omittedGlyphs
                ? "Glyph atlas capacity exceeded; some glyphs were omitted."
                : "Glyph atlas capacity exceeded; retrying with a fresh atlas.")
        }
    }

    /// Clear the reporting interval without resetting active GPU ownership.
    func reset() {
        lock.withLock {
            let flights = state.flights
            let next = state.nextSubmission
            state = State()
            state.flights = flights
            state.nextSubmission = next
        }
    }

    /// Include replaced resources still used by outstanding commands, counting
    /// each allocation once. Defaults let accounting tests run without Metal.
    func snapshot(device: String = "Unavailable", drawableWidth: Int = 0, drawableHeight: Int = 0,
                  pendingFrame: Bool = false, atlas: Allocation? = nil,
                  buffers: [Allocation] = []) -> RenderDiagnosticsSnapshot {
        lock.withLock {
            var atlases: [ObjectIdentifier: Int] = [:]
            var allocatedBuffers: [ObjectIdentifier: Int] = [:]
            if let atlas { atlases[atlas.id] = atlas.bytes }
            for buffer in buffers { allocatedBuffers[buffer.id] = buffer.bytes }
            for flight in state.flights.values {
                if let atlas = flight.atlas { atlases[atlas.id] = atlas.bytes }
                if let buffer = flight.buffer { allocatedBuffers[buffer.id] = buffer.bytes }
            }
            return RenderDiagnosticsSnapshot(
                device: device, drawableWidth: drawableWidth, drawableHeight: drawableHeight,
                framesSubmitted: state.framesSubmitted, framesCompleted: state.framesCompleted,
                framesFailed: state.framesFailed, pendingFrame: pendingFrame,
                inFlight: state.flights.count, deferred: state.deferred,
                lastCPUFrameMS: state.lastCPUFrameMS, maxCPUFrameMS: state.maxCPUFrameMS,
                lastGPUFrameMS: state.lastGPUFrameMS, atlasBytes: atlases.values.reduce(0, +),
                bufferBytes: allocatedBuffers.values.reduce(0, +), issues: state.issues)
        }
    }
}

/// Draws a terminal into a CAMetalLayer: every cell's background, glyph and
/// decorations as instanced quads, in one draw call.
///
/// Each frame reads libghostty-vt's render state and rebuilds only the rows
/// it marks dirty; the rest come from a per-row cache. A frame is only drawn
/// when something changed.
///
/// Presentation can fail (no drawable, a zero-size layer, or three frames
/// already in flight): `render` and `clear` return whether the frame went out,
/// and a frame that did not stays pending in the renderer, so the caller just
/// calls again on its next tick. Only the in-flight limit is checked without
/// waiting; `nextDrawable` may still wait briefly for the display.
@MainActor
final class Renderer {
    /// One quad. `kind` 0 fills with `color`; 1 tints the atlas mask with
    /// `color`; 2 draws the atlas texel as is (color emoji); 3 fades `color`
    /// from full at its top edge to clear at its bottom.
    struct Quad {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var uvOrigin: SIMD2<Float>
        var color: SIMD4<Float>
        var kind: UInt32
        var _pad: UInt32 = 0
    }

    private struct Row {
        var backgrounds: [Quad] = []
        var glyphs: [Quad] = []
        var decorations: [Quad] = []
        /// The glyph quad at each column, for drawing the cell under a block
        /// cursor in the background color.
        var glyphAt: [UInt16: Quad] = [:]
    }

    /// The device, shader library and pipeline are immutable and costly to
    /// build, so every renderer (one per pane) shares one set.
    private static let shared: (device: MTLDevice, pipeline: MTLRenderPipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do {
            let library = try device.makeLibrary(source: shaders, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "quad_vertex")
            desc.fragmentFunction = library.makeFunction(name: "quad_fragment")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.sourceRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return (device, try device.makeRenderPipelineState(descriptor: desc))
        } catch {
            print("koi: shaders failed: \(error)")
            return nil
        }
    }()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var atlas: GlyphAtlas
    private var rows: [Row] = []
    private var atlasGeneration = -1
    private let renderState: GhosttyRenderState
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var colors = GhosttyRenderStateColors()
    private(set) var quads: [Quad] = []
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private let diagnosticStats = RenderDiagnosticsStats()
    private weak var diagnosticLayer: CAMetalLayer?

    /// Read on demand; no frame-driven observable updates or polling timers.
    var diagnostics: RenderDiagnosticsSnapshot {
        let size = diagnosticLayer?.drawableSize ?? .zero
        return diagnosticStats.snapshot(
            device: device.name, drawableWidth: Int(size.width), drawableHeight: Int(size.height),
            pendingFrame: framePending,
            atlas: .init(id: ObjectIdentifier(atlas.texture), bytes: atlas.texture.allocatedSize),
            buffers: buffers.map { .init(id: ObjectIdentifier($0), bytes: $0.allocatedSize) })
    }

    /// Reset history while preserving pending work and live flights. Older
    /// completions retire their flights without entering the new counters.
    func resetDiagnostics() {
        diagnosticStats.reset()
    }

    /// Whether the pane has keyboard focus; inactive panes use an outline cursor.
    var focused = true
    /// The viewport is above the live screen: scrolled-back rows fade out
    /// under the top edge instead of stopping at it.
    private var scrolledBack = false
    /// The inset of the grid from the layer's edges, in pixels.
    var padding = SIMD2<Float>(0, 0)
    /// Predicted typing drawn over the grid, with the cursor at its caret.
    var overlay = Prediction.Overlay() {
        didSet { overlayChanged = overlayChanged || overlay != oldValue }
    }
    /// Hides the cursor, for a terminal whose first real output has not
    /// arrived, so an empty snapshot does not show a blank block.
    var hidesCursor = false {
        didSet { overlayChanged = overlayChanged || hidesCursor != oldValue }
    }
    /// The overlay or cursor visibility changed since the last presented frame.
    private var overlayChanged = false
    /// A frame was assembled, consuming the engine's dirtiness, but has not
    /// been presented yet.
    private var framePending = false
    /// The cursor and scroll position as last drawn. The engine does not
    /// count a cursor move as dirty (erasing a space changes no cell), so
    /// the renderer watches these itself.
    private var drawnCursor = GhosttyRenderStateCursor()
    private var drawnScroll = GhosttyTerminalScrollbar()

    init?(metrics: FontMetrics, atlasSize: Int = 2048) {
        guard let shared = Self.shared, let queue = shared.device.makeCommandQueue() else { return nil }
        device = shared.device
        pipeline = shared.pipeline
        self.queue = queue
        atlas = GlyphAtlas(device: device, metrics: metrics, size: atlasSize)
        // Assigned only once all three exist, so a failed allocation frees
        // what was made and leaves nothing for deinit to double-free.
        var state: GhosttyRenderState?
        var iterator: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        ghostty_render_state_new(nil, &state)
        ghostty_render_state_row_iterator_new(nil, &iterator)
        ghostty_render_state_row_cells_new(nil, &cells)
        guard let state, let iterator, let cells else {
            if let state { ghostty_render_state_free(state) }
            if let iterator { ghostty_render_state_row_iterator_free(iterator) }
            if let cells { ghostty_render_state_row_cells_free(cells) }
            return nil
        }
        renderState = state
        rowIterator = iterator
        rowCells = cells
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
    }

    isolated deinit {
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        ghostty_render_state_free(renderState)
    }

    /// Replaces the atlas; callers should skip this when the font size, scale
    /// and family are unchanged, since a new atlas redraws every glyph.
    func setMetrics(_ metrics: FontMetrics) {
        atlas = GlyphAtlas(device: device, metrics: metrics)
        atlasGeneration = -1
    }

    /// Draws just the background, for a pane that has no terminal yet, so
    /// its card never shows bare frost. Returns whether it was presented.
    @discardableResult
    func clear(into layer: CAMetalLayer) -> Bool {
        let started = CACurrentMediaTime()
        diagnosticLayer = layer
        if atlasGeneration != atlas.generation { rows.removeAll() }
        if rows.isEmpty { colors.background = Theme.current.background }
        scrolledBack = false
        assembleFrame(full: nil)
        framePending = !draw(into: layer, started: started)
        return !framePending
    }

    /// Renders the terminal's current state into `layer`, if anything
    /// changed since the last frame (or `force`). Returns false only when a
    /// frame was due but could not be presented; it is then retried by the
    /// next call without losing the changes it holds.
    @discardableResult
    func render(_ terminal: VTTerminal, into layer: CAMetalLayer, force: Bool = false) -> Bool {
        let started = CACurrentMediaTime()
        diagnosticLayer = layer
        if prepareFrame(terminal, force: force) { framePending = true }
        guard framePending else { return true }
        framePending = !draw(into: layer, started: started)
        return !framePending
    }

    /// Updates cached rows and assembles one coherent atlas generation, without
    /// requiring a drawable. Returns false when there is nothing new to draw.
    func prepareFrame(_ terminal: VTTerminal, force: Bool = false) -> Bool {
        guard ghostty_render_state_update(renderState, terminal.raw) == GHOSTTY_SUCCESS else { return false }
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        let moved = cursorOrScrollMoved(terminal)
        scrolledBack = !terminal.viewportIsActive
        let invalidAtlas = atlasGeneration != atlas.generation
        if !force, dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE, !invalidAtlas {
            guard overlayChanged || moved else { return false }
            assembleFrame(full: nil)
            return true
        }

        var rowCount: UInt16 = 0
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let full = force || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || rows.count != Int(rowCount)
            || invalidAtlas
        if rows.count != Int(rowCount) { rows = Array(repeating: Row(), count: Int(rowCount)) }
        assembleFrame(full: full)
        ghostty_render_state_clean(renderState)
        return true
    }

    /// Pins the atlas across ALL UV producers. Retry once after eviction to
    /// reclaim offscreen glyphs. If the visible set itself exceeds capacity,
    /// omit excess glyphs rather than looping or retaining unbounded textures.
    private func assembleFrame(full: Bool?) {
        for attempt in 0..<2 {
            atlas.beginFrame()
            if let full { buildRows(full: full || attempt == 1) }
            else if attempt == 1 { buildRows(full: true) }
            quads.removeAll(keepingCapacity: true)
            for r in rows { quads.append(contentsOf: r.backgrounds) }
            let cursorQuads = cursor()
            quads.append(contentsOf: cursorQuads.under)
            for r in rows { quads.append(contentsOf: r.glyphs) }
            for r in rows { quads.append(contentsOf: r.decorations) }
            quads.append(contentsOf: overlayQuads())
            quads.append(contentsOf: cursorQuads.over)
            if scrolledBack { quads.append(topFade()) }
            atlas.endFrame()
            if atlas.overflowed { diagnosticStats.atlasOverflow(omittedGlyphs: attempt == 1) }
            if atlas.overflowed && attempt == 0 {
                atlas.reset()
                continue
            }
            atlasGeneration = atlas.generation
            break
        }
    }

    /// Rebuilds the cached rows from the render state: all of them, or only
    /// the dirty ones.
    private func buildRows(full: Bool) {
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        if full {
            var y = 0
            while ghostty_render_state_row_iterator_next(rowIterator), y < rows.count {
                rows[y] = buildRow(y)
                y += 1
            }
        } else {
            var y: UInt16 = 0
            while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
                if Int(y) < rows.count { rows[Int(y)] = buildRow(Int(y)) }
            }
        }
    }

    /// Whether the cursor or the viewport is elsewhere than when last
    /// drawn, remembering where they are now.
    private func cursorOrScrollMoved(_ terminal: VTTerminal) -> Bool {
        var c = GhosttyRenderStateCursor()
        c.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &c)
        var scroll = GhosttyTerminalScrollbar()
        ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scroll)
        let moved = withUnsafeBytes(of: c) { a in withUnsafeBytes(of: drawnCursor) { b in a.elementsEqual(b) } } == false
            || scroll.offset != drawnScroll.offset || scroll.total != drawnScroll.total
        drawnCursor = c
        drawnScroll = scroll
        return moved
    }

    /// While scrolled back, the top padding and first row dissolve into the
    /// background, so earlier output reads as continuing under the header
    /// rather than being cut off by it. At the live screen nothing is drawn.
    private func topFade() -> Quad {
        let ch = Float(atlas.metrics.cellHeight)
        let width = Float(diagnosticLayer?.drawableSize.width ?? 0)
        return Quad(origin: [-padding.x, -padding.y], size: [width, padding.y + ch], uvOrigin: .zero,
                    color: premultiplied(colors.background, alpha: Float(Config.current.backgroundOpacity)), kind: 3)
    }

    /// The overlay's quads: each predicted cell painted in the default
    /// colors over whatever the grid shows there.
    private func overlayQuads() -> [Quad] {
        var out: [Quad] = []
        let m = atlas.metrics
        let cw = Float(m.cellWidth), ch = Float(m.cellHeight)
        let bg = premultiplied(colors.background), fg = premultiplied(colors.foreground)
        for cell in overlay.cells where Int(cell.y) < rows.count {
            let origin = SIMD2<Float>(Float(cell.x) * cw, Float(cell.y) * ch)
            out.append(Quad(origin: origin, size: [cw, ch], uvOrigin: .zero, color: bg, kind: 0))
            guard cell.text != " ", let e = atlas.entry(.init(text: cell.text, bold: false, italic: false, wide: false)) else { continue }
            let pad = Float(atlas.pad)
            out.append(Quad(origin: [origin.x - pad, origin.y - pad], size: [Float(e.width), Float(e.height)],
                            uvOrigin: [Float(e.x), Float(e.y)], color: e.colored ? [1, 1, 1, 1] : fg, kind: e.colored ? 2 : 1))
        }
        return out
    }

    private func buildRow(_ y: Int) -> Row {
        var row = Row()
        ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
        let m = atlas.metrics
        let cw = Float(m.cellWidth), ch = Float(m.cellHeight)
        let top = Float(y) * ch
        let defaultFg = colors.foreground, defaultBg = colors.background
        var style = GhosttyStyle()
        var codepoints = [UInt32](repeating: 0, count: 32)
        var x: UInt16 = 0

        while ghostty_render_state_row_cells_next(rowCells) {
            defer { x += 1 }
            style.size = MemoryLayout<GhosttyStyle>.size
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
            var fg = defaultFg, bg = defaultBg
            let hasFg = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS
            let hasBg = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS
            if !hasFg { fg = defaultFg }
            if !hasBg { bg = defaultBg }
            var selected = false
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected)
            var fillBg = hasBg
            if style.inverse {
                swap(&fg, &bg)
                fillBg = true
            }
            // Selection is independent of SGR inverse: combining them with
            // OR leaves selected inverse cells visually unchanged.
            if selected {
                swap(&fg, &bg)
                fillBg = true
            }
            let left = Float(x) * cw
            if fillBg {
                row.backgrounds.append(Quad(origin: [left, top], size: [cw, ch], uvOrigin: .zero, color: premultiplied(bg), kind: 0))
            }

            var len: UInt32 = 0
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
            guard len > 0, !style.invisible else { continue }
            if Int(len) > codepoints.count { codepoints = [UInt32](repeating: 0, count: Int(len)) }
            codepoints.withUnsafeMutableBufferPointer {
                _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress)
            }
            var text = String.UnicodeScalarView()
            for cp in codepoints[0..<Int(len)] { if let s = Unicode.Scalar(cp) { text.append(s) } }
            let wide = isWide()
            if wide, fillBg {
                row.backgrounds.append(Quad(origin: [left + cw, top], size: [cw, ch], uvOrigin: .zero, color: premultiplied(bg), kind: 0))
            }
            let color = premultiplied(fg, alpha: style.faint ? 0.5 : 1)
            if text.count == 1, text.first == " " {
                // Nothing to draw but its decorations.
            } else if let e = atlas.entry(.init(text: String(text), bold: style.bold, italic: style.italic, wide: wide)) {
                let pad = Float(atlas.pad)
                let q = Quad(origin: [left - pad, top - pad], size: [Float(e.width), Float(e.height)],
                             uvOrigin: [Float(e.x), Float(e.y)], color: e.colored ? [1, 1, 1, 1] : color,
                             kind: e.colored ? 2 : 1)
                row.glyphs.append(q)
                row.glyphAt[x] = q
            }
            let span = wide ? cw * 2 : cw
            let thick = Float(m.lineThickness)
            if style.underline != 0 {
                let yLine = top + ch - Float(m.underlinePosition)
                row.decorations.append(Quad(origin: [left, yLine], size: [span, thick], uvOrigin: .zero, color: color, kind: 0))
            }
            if style.strikethrough {
                let yLine = top + ch / 2
                row.decorations.append(Quad(origin: [left, yLine], size: [span, thick], uvOrigin: .zero, color: color, kind: 0))
            }
        }
        return row
    }

    private func isWide() -> Bool {
        var cell = GhosttyCell()
        guard ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &cell) == GHOSTTY_SUCCESS else { return false }
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
        return wide == GHOSTTY_CELL_WIDE_WIDE
    }

    /// Encodes and presents `quads`. Returns false, having consumed nothing,
    /// when the layer has no size, all frames in flight are still on the GPU,
    /// or drawable/command/buffer/encoder allocation is unavailable.
    private func draw(into layer: CAMetalLayer, started: CFTimeInterval) -> Bool {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else {
            diagnosticStats.deferFrame(.zeroSize)
            return false
        }
        guard inflight.wait(timeout: .now()) == .success else {
            diagnosticStats.deferFrame(.inflight)
            return false
        }
        var completionOwnsFlight = false
        defer { if !completionOwnsFlight { inflight.signal() } }
        guard let drawable = layer.nextDrawable() else {
            diagnosticStats.deferFrame(.noDrawable)
            return false
        }
        guard let cmd = queue.makeCommandBuffer() else {
            diagnosticStats.deferFrame(.commandBuffer)
            return false
        }
        let bytes = max(1, quads.count) * MemoryLayout<Quad>.stride
        if bufferIndex >= buffers.count || buffers[bufferIndex].length < bytes {
            guard let buf = device.makeBuffer(length: bytes * 2, options: .storageModeShared) else {
                diagnosticStats.deferFrame(.buffer)
                return false
            }
            if bufferIndex == buffers.count { buffers.append(buf) } else { buffers[bufferIndex] = buf }
        }
        let buffer = buffers[bufferIndex]
        quads.withUnsafeBytes { if let base = $0.baseAddress { buffer.contents().copyMemory(from: base, byteCount: $0.count) } }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = premultiplied(colors.background, alpha: Float(Config.current.backgroundOpacity))
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            diagnosticStats.deferFrame(.encoder)
            return false
        }
        if !quads.isEmpty {
            enc.setRenderPipelineState(pipeline)
            var view = SIMD4<Float>(Float(drawable.texture.width), Float(drawable.texture.height), padding.x, padding.y)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&view, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
        }
        enc.endEncoding()
        let sem = inflight
        let stats = diagnosticStats
        // An empty draw binds neither resource, so its command does not keep
        // a replaced atlas or buffer alive.
        let submission = stats.submitted(
            atlas: quads.isEmpty ? nil : .init(id: ObjectIdentifier(atlas.texture), bytes: atlas.texture.allocatedSize),
            buffer: quads.isEmpty ? nil : .init(id: ObjectIdentifier(buffer), bytes: buffer.allocatedSize))
        cmd.addCompletedHandler { [sem, stats, submission] completed in
            defer { sem.signal() }
            stats.completed(submission, succeeded: completed.status == .completed,
                            error: completed.error as NSError?,
                            gpuStartTime: completed.gpuStartTime, gpuEndTime: completed.gpuEndTime)
        }
        let presentsWithTransaction = layer.presentsWithTransaction
        if !presentsWithTransaction { cmd.present(drawable) }
        completionOwnsFlight = true
        cmd.commit()
        stats.recordCPUFrame((CACurrentMediaTime() - started) * 1000, for: submission)
        // A failed encoding must retry this same slot, rather than skipping to
        // a buffer that another command may still be reading.
        bufferIndex = (bufferIndex + 1) % 3
        overlayChanged = false
        if presentsWithTransaction {
            // The frame goes out with the current Core Animation transaction,
            // so a resized pane never shows its old frame stretched.
            cmd.waitUntilScheduled()
            drawable.present()
        }
        return true
    }

    /// The cursor's quads: a block goes under the text with the glyph
    /// redrawn in the background color; other shapes go over it.
    private func cursor() -> (under: [Quad], over: [Quad]) {
        var c = GhosttyRenderStateCursor()
        c.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &c)
        guard !hidesCursor, c.visible, c.viewport_has_value, Int(c.viewport_y) < rows.count else { return ([], []) }
        // While typing is predicted, the cursor shows where the typing has
        // reached, past the predicted cells.
        if let caret = overlay.caret {
            c.viewport_x = caret.x
            c.viewport_y = caret.y
        }
        guard Int(c.viewport_y) < rows.count else { return ([], []) }
        let m = atlas.metrics
        let cw = Float(m.cellWidth), ch = Float(m.cellHeight)
        let origin = SIMD2<Float>(Float(c.viewport_x) * cw, Float(c.viewport_y) * ch)
        let color = premultiplied(colors.cursor_has_value ? colors.cursor : colors.foreground,
                                  alpha: Float(Config.current.cursorOpacity))
        let thick = max(2, Float(m.lineThickness) * 2)
        // The block fills the glyph box (the cell without its line leading),
        // scaled by `cursor-height` and centered, so it hugs the text instead
        // of the whole line.
        let fullHeight = Config.current.cursorHeight >= 1
        let boxH = (ch - Float(m.leading)) * Float(Config.current.cursorHeight)
        let boxTop = origin.y + (ch - boxH) / 2

        func outline() -> [Quad] {
            [Quad(origin: [origin.x, boxTop], size: [cw, thick / 2], uvOrigin: .zero, color: color, kind: 0),
             Quad(origin: [origin.x, boxTop + boxH - thick / 2], size: [cw, thick / 2], uvOrigin: .zero, color: color, kind: 0),
             Quad(origin: [origin.x, boxTop], size: [thick / 2, boxH], uvOrigin: .zero, color: color, kind: 0),
             Quad(origin: [origin.x + cw - thick / 2, boxTop], size: [thick / 2, boxH], uvOrigin: .zero, color: color, kind: 0)]
        }
        if !focused { return ([], outline()) }
        switch c.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
            return ([], [Quad(origin: [origin.x, boxTop], size: [thick, boxH], uvOrigin: .zero, color: color, kind: 0)])
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
            return ([], [Quad(origin: [origin.x, origin.y + ch - thick], size: [cw, thick], uvOrigin: .zero, color: color, kind: 0)])
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
            return ([], outline())
        default:
            var under = [Quad(origin: [origin.x, boxTop], size: [cw, boxH], uvOrigin: .zero, color: color, kind: 0)]
            // Repaint the covered glyph in the background color so it reads
            // against the block — only when the block spans the whole glyph,
            // or a shrunk cursor would tint the parts it doesn't cover.
            if fullHeight, var g = rows[Int(c.viewport_y)].glyphAt[c.viewport_x], g.kind == 1 {
                g.color = premultiplied(colors.background)
                under.append(g)
            }
            return (under, [])
        }
    }

    private func premultiplied(_ c: GhosttyColorRgb, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(c.r) / 255 * alpha, Float(c.g) / 255 * alpha, Float(c.b) / 255 * alpha, alpha)
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad {
        float2 origin;
        float2 size;
        float2 uv_origin;
        float4 color;
        uint kind;
        uint pad;
    };

    struct Out {
        float4 position [[position]];
        float2 uv;
        float4 color;
        uint kind [[flat]];
    };

    vertex Out quad_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Quad *quads [[buffer(0)]],
                           constant float4 &view [[buffer(1)]]) {
        // view: drawable width and height, then the grid's x and y offset.
        Quad q = quads[iid];
        float2 corner = float2(vid & 1, vid >> 1);
        float2 px = q.origin + view.zw + corner * q.size;
        float2 viewport = view.xy;
        Out o;
        o.position = float4(px.x / viewport.x * 2 - 1, 1 - px.y / viewport.y * 2, 0, 1);
        o.uv = q.kind == 3 ? corner : q.uv_origin + corner * q.size;
        o.color = q.color;
        o.kind = q.kind;
        return o;
    }

    fragment float4 quad_fragment(Out in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        if (in.kind == 0) return in.color;
        if (in.kind == 3) return in.color * (1 - in.uv.y);
        constexpr sampler s(coord::pixel, filter::nearest);
        float4 t = atlas.sample(s, in.uv);
        if (in.kind == 2) return t;
        return in.color * t.a;
    }
    """
}
