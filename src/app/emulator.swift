import GhosttyVt

/// Owns one libghostty-vt terminal: the screen, scrollback and parser state
/// that both the server (headless, authoritative) and each app pane (for
/// drawing) keep. Not thread-safe; each owner uses it from one queue.
final class VTTerminal {
    let raw: GhosttyTerminal
    /// Runs synchronously on the terminal's owning queue, at the exact VT hold boundary.
    var onRenderHold: ((Bool) -> Void)?
    /// Explicit local viewport/selection changes may interrupt a synchronized redraw.
    var onViewportInteraction: (() -> Void)?

    /// Synchronous text-only clipboard sink for live output. Mirrors install
    /// this after restoration; headless terminals never access a clipboard.
    var onClipboardWrite: ((String) -> Bool)?
    private var oscNumber: Int?
    private var readingOSCNumber = false

    /// Default history for a fresh mirror; snapshots carry the server's limit.
    static let scrollbackBytes = 32 * 1024 * 1024

    init(cols: UInt16, rows: UInt16) {
        var t: GhosttyTerminal?
        precondition(ghostty_terminal_new(nil, &t, cols, rows) == GHOSTTY_SUCCESS)
        raw = t!
        configure()
    }

    /// Restores a terminal from a snapshot made by `snapshot()`; nil if the
    /// bytes are not a complete snapshot.
    init?(snapshot bytes: [UInt8]) {
        var decoder: GhosttySnapshotDecoder?
        let made = bytes.withUnsafeBufferPointer {
            ghostty_snapshot_decoder_new_buf(nil, &decoder, $0.baseAddress, $0.count)
        }
        guard made == GHOSTTY_SUCCESS, let decoder else { return nil }
        defer { ghostty_snapshot_decoder_free(decoder) }
        var retain = true
        var limit = 64 * 1024
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit)
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain)
        var t: GhosttyTerminal?
        guard ghostty_snapshot_decoder_decode(decoder, &t) == GHOSTTY_SUCCESS, let t else { return nil }
        raw = t
        configure(restored: true)
    }

    deinit {
        // Search owns native allocations and references into this grid.
        if let search { ghostty_search_free(search) }
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, nil)
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_USERDATA, nil)
        ghostty_terminal_free(raw)
    }

    private func configure(restored: Bool = false) {
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let hold: GhosttyTerminalRenderHoldFn = { _, userdata, held in
            guard let userdata else { return }
            Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue().onRenderHold?(held)
        }
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(hold, to: UnsafeRawPointer.self))
        // A snapshot owns the server's colors and history limit. Overriding
        // them here would silently undo configurePane in attached mirrors.
        // This cooperation cannot change old v6 binaries, which restore 32 MiB;
        // configured history limits are not a privacy guarantee across clients.
        if !restored {
            var scrollback = Self.scrollbackBytes
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)
            Theme.current.apply(to: raw)
        }
        // Snapshots need the parser's unfinished input, so track it.
        var continuation = 64 * 1024
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation)
        // Join multi-codepoint graphemes (flags, skin tones, ZWJ emoji) into
        // one cell, as Ghostty and the server do. A restored terminal keeps
        // the mode's current value from the snapshot, but a reset must return
        // it to this default too, or the mirror and the server would diverge.
        // Setting the default also sets the current value, so a restored
        // terminal gets what its program had left put back.
        var current = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_MODE, &current)
        var grapheme = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &grapheme)
        if restored { ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_MODE, &current) }
        applyCursorStyle()
        installClipboardHandler()
        if restored { restoreOSCNumber() }
    }

    /// The engine decodes clipboard contents; only OSC 52 may write the Mac
    /// clipboard. Acknowledged protocols need server/client reply routing first.
    /// Callback data is borrowed until return; reads are never exposed.
    private func installClipboardHandler() {
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        var limit = 1024 * 1024
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES, &limit)
        let callback: GhosttyTerminalClipboardWriteFn = { _, userdata, request in
            guard let userdata, let request,
                  request.pointee.size >= MemoryLayout<GhosttyClipboardWrite>.size else { return }
            let terminal = Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
            var reply = GhosttyClipboardWriteReply()
            reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
            reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
            defer { request.pointee.reply?(request, &reply) }
            guard terminal.oscNumber == 52 else { return }
            guard request.pointee.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD else { return }
            // macOS has one system clipboard. A protocol clear writes empty
            // text; primary/selection destinations are unsupported.
            if request.pointee.contents_len == 0 {
                reply.result = terminal.onClipboardWrite?("") == true
                    ? GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS : GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
                return
            }
            guard request.pointee.contents_len == 1, let content = request.pointee.contents?.pointee,
                  let mime = content.mime.ptr, content.mime.len == 10,
                  String(decoding: UnsafeBufferPointer(start: mime, count: 10), as: UTF8.self) == "text/plain",
                  content.data.len <= 1024 * 1024 else { return }
            let bytes = UnsafeBufferPointer(start: content.data.ptr, count: content.data.len)
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
                return
            }
            reply.result = terminal.onClipboardWrite?(text) == true
                ? GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS : GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
        }
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                             unsafeBitCast(callback, to: UnsafeRawPointer.self))
    }

    /// Re-applies the current theme and cursor, after a config reload.
    func applyTheme() { Theme.current.apply(to: raw); applyCursorStyle() }

    /// Sets the shape the cursor falls back to (`cursor-style`); a program's
    /// own DECSCUSR still overrides it. Nil leaves the built-in block default.
    private func applyCursorStyle() {
        guard let style = Config.current.cursorStyle else {
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, nil)
            return
        }
        var s: GhosttyTerminalCursorStyle
        switch style {
        case .block: s = GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
        case .bar: s = GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
        case .underline: s = GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE
        case .hollow: s = GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW
        }
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &s)
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        let data = base.assumingMemoryBound(to: UInt8.self)
        let start = UInt32(GHOSTTY_TERMINAL_BOUNDARY_OSC_START.rawValue)
        let end = UInt32(GHOSTTY_TERMINAL_BOUNDARY_OSC_END.rawValue)
        var offset = 0
        while offset < bytes.count {
            // Ask the engine for framing; inspect only the command number.
            // Ordinary output and the entire payload still use bulk writes.
            let count = readingOSCNumber ? 1 : bytes.count - offset
            if readingOSCNumber { observeOSCNumber(data[offset]) }
            var stop = GhosttyTerminalWriteStop()
            stop.size = MemoryLayout<GhosttyTerminalWriteStop>.size
            let result = ghostty_terminal_vt_write_until(raw, data + offset, count, start | end, &stop)
            precondition(result == GHOSTTY_SUCCESS || result == GHOSTTY_NO_VALUE)
            precondition(stop.consumed > 0)
            offset += stop.consumed
            if stop.reached & end != 0 { readingOSCNumber = false; oscNumber = nil }
            if stop.reached & start != 0 { readingOSCNumber = true; oscNumber = 0 }
        }
    }

    /// Track a bounded OSC command identifier, never its payload or framing.
    private func observeOSCNumber(_ byte: UInt8) {
        if byte == 59 { readingOSCNumber = false }
        else if (48...57).contains(byte), let number = oscNumber, number < 10_000 {
            oscNumber = number * 10 + Int(byte - 48)
        } else if byte < 32, byte != 7, byte != 24, byte != 26, byte != 27 {
            return // C0 controls ignored by the engine within an OSC header.
        } else { oscNumber = nil; readingOSCNumber = false }
    }

    /// Snapshot decoding replays unfinished input before callbacks are installed.
    /// Recover just an unfinished OSC's identifier without replaying side effects.
    private func restoreOSCNumber() {
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_terminal_continuation_alloc(raw, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return }
        defer { ghostty_free(nil, ptr, len) }
        guard len >= 2, ptr[0] == 27, ptr[1] == 93 || ptr[1] == 157 else { return }
        readingOSCNumber = true
        oscNumber = 0
        for byte in UnsafeBufferPointer(start: ptr + 2, count: len - 2) {
            guard readingOSCNumber else { break }
            observeOSCNumber(byte)
        }
    }

    func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { write($0) }
    }

    func resize(_ size: GridSize) {
        ghostty_terminal_resize(raw, size.cols, size.rows, size.cellWidth, size.cellHeight)
    }

    /// Releases a timed-out synchronized redraw; direct mode changes do not invoke callbacks.
    func endRenderHold() {
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_MODE, &mode)
    }

    /// The complete state: screen, modes, scrollback and unfinished input.
    func snapshot() -> [UInt8] {
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_snapshot_encode_alloc(raw, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return [] }
        defer { ghostty_free(nil, ptr, len) }
        return Array(UnsafeBufferPointer(start: ptr, count: len))
    }

    /// The screen and scrollback as plain text, trailing blanks trimmed.
    func text() -> String {
        var opts = GhosttyFormatterTerminalOptions()
        opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.trim = true
        opts.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        opts.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, raw, opts) == GHOSTTY_SUCCESS, let formatter else { return "" }
        defer { ghostty_formatter_free(formatter) }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return "" }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    var size: (cols: UInt16, rows: UInt16) {
        var cols: UInt16 = 0, rows: UInt16 = 0
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        return (cols, rows)
    }

    /// Whether a full-screen program has switched to the alternate screen.
    var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    /// The text in a cell of the active area, "" when empty.
    func text(x: UInt16, y: UInt16) -> String {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: x, y: UInt32(y))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(raw, point, &ref) == GHOSTTY_SUCCESS else { return "" }
        var buf = [UInt32](repeating: 0, count: 16)
        var len = 0
        guard ghostty_grid_ref_graphemes(&ref, &buf, buf.count, &len) == GHOSTTY_SUCCESS, len > 0 else { return "" }
        var s = String.UnicodeScalarView()
        for cp in buf[0..<len] { if let scalar = Unicode.Scalar(cp) { s.append(scalar) } }
        return String(s)
    }

    // MARK: Selection

    /// A grid reference for a viewport cell (what the mouse points at), or
    /// nil if that cell is off the grid.
    private func viewportRef(col: UInt16, row: UInt16) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: col, y: UInt32(row))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(raw, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    /// Selects the range between two viewport cells, inclusive. The engine
    /// tracks the selection from here, so the refs needn't outlive this call.
    func select(from: (col: UInt16, row: UInt16), to: (col: UInt16, row: UInt16)) {
        guard let start = viewportRef(col: from.col, row: from.row),
              let end = viewportRef(col: to.col, row: to.row) else { return }
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        sel.start = start
        sel.end = end
        sel.rectangle = false
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SELECTION, &sel)
        onViewportInteraction?()
    }

    /// Selects the whole screen and scrollback.
    func selectAll() {
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_select_all(raw, &sel) == GHOSTTY_SUCCESS else { return }
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SELECTION, &sel)
        onViewportInteraction?()
    }

    func clearSelection() {
        ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    var hasSelection: Bool {
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        return ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS
    }

    /// The active selection as plain text, soft-wrapped lines joined, or nil
    /// if nothing is selected.
    func selectedText() -> String? {
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.unwrap = true
        opts.trim = true
        opts.selection = nil  // The terminal's current selection.
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_terminal_selection_format_alloc(raw, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS,
              let ptr, len > 0 else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    /// The text of a viewport cell, " " when empty, for hit-testing URLs.
    private func viewportCellText(col: UInt16, row: UInt16) -> String {
        guard var ref = viewportRef(col: col, row: row) else { return " " }
        var buf = [UInt32](repeating: 0, count: 16)
        var len = 0
        guard ghostty_grid_ref_graphemes(&ref, &buf, buf.count, &len) == GHOSTTY_SUCCESS, len > 0 else { return " " }
        var s = String.UnicodeScalarView()
        for cp in buf[0..<len] { if let scalar = Unicode.Scalar(cp) { s.append(scalar) } }
        return String(s)
    }

    /// A viewport row as one string per column, so a click column indexes
    /// straight into it (used to find a URL under the pointer).
    func viewportRow(_ row: UInt16) -> [String] {
        (0..<size.cols).map { viewportCellText(col: $0, row: row) }
    }

    // MARK: Search

    private var search: GhosttySearch?
    private var searchNeedle: [UInt8] = []

    /// Starts (or restarts) a scrollback search and returns the match count.
    /// Selecting a match (searchSelect) highlights it and scrolls to it.
    func searchStart(_ needle: String) -> Int {
        searchEnd()
        guard !needle.isEmpty else { return 0 }
        var s: GhosttySearch?
        guard ghostty_search_new(nil, &s, raw) == GHOSTTY_SUCCESS, let s else { return 0 }
        search = s
        searchNeedle = Array(needle.utf8)
        searchNeedle.withUnsafeBufferPointer { buf in
            var str = GhosttyString(ptr: buf.baseAddress, len: buf.count)
            ghostty_search_set(s, GHOSTTY_SEARCH_OPT_NEEDLE, &str)
        }
        _ = ghostty_search_run(s)
        var total = 0
        ghostty_search_get(s, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        return total
    }

    /// Selects the next or previous match, scrolling to it. Returns the
    /// 1-based match index and total, or nil when there are no matches.
    func searchSelect(next: Bool) -> (index: Int, total: Int)? {
        guard let s = search else { return nil }
        var scroll = GHOSTTY_SEARCH_SCROLL_IF_NEEDED
        ghostty_search_set(s, GHOSTTY_SEARCH_OPT_SELECT_SCROLL, &scroll)
        guard ghostty_search_set(s, next ? GHOSTTY_SEARCH_OPT_SELECT_NEXT : GHOSTTY_SEARCH_OPT_SELECT_PREV, nil) == GHOSTTY_SUCCESS else { return nil }
        // The search scrolls to the match but leaves the active selection to
        // us: apply the match so the renderer highlights it.
        var match = GhosttySelection()
        match.size = MemoryLayout<GhosttySelection>.size
        if ghostty_search_get(s, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match) == GHOSTTY_SUCCESS {
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SELECTION, &match)
        }
        var index = 0, total = 0
        guard ghostty_search_get(s, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS else { return nil }
        ghostty_search_get(s, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        return (index + 1, total)
    }

    func searchEnd() {
        if let s = search { ghostty_search_free(s) }
        search = nil
        searchNeedle = []
        clearSelection()
    }

    /// Whether the viewport shows the active area (not scrolled back).
    var viewportIsActive: Bool { flag(GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE) }
    var cursorVisible: Bool { flag(GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE) }
    /// The cursor sits past the last column, waiting to wrap.
    var cursorPendingWrap: Bool { flag(GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP) }

    private func flag(_ key: GhosttyTerminalData) -> Bool {
        var v = false
        ghostty_terminal_get(raw, key, &v)
        return v
    }

    /// The cursor's cell in the active area.
    var cursor: (x: UInt16, y: UInt16) {
        var x: UInt16 = 0, y: UInt16 = 0
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        return (x, y)
    }

    /// The window title the program set (OSC 0/2), or "".
    var title: String { string(GHOSTTY_TERMINAL_DATA_TITLE) }

    /// The working directory the shell reported (OSC 7), or "".
    var pwd: String { string(GHOSTTY_TERMINAL_DATA_PWD) }

    private func string(_ key: GhosttyTerminalData) -> String {
        var s = GhosttyString()
        guard ghostty_terminal_get(raw, key, &s) == GHOSTTY_SUCCESS, let p = s.ptr, s.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: s.len), as: UTF8.self)
    }

    func scroll(_ behavior: GhosttyTerminalScrollViewport) {
        var before = GhosttyTerminalScrollbar(), after = GhosttyTerminalScrollbar()
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &before)
        ghostty_terminal_scroll_viewport(raw, behavior)
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &after)
        if before.offset != after.offset { onViewportInteraction?() }
    }

    func scroll(rows delta: Int) {
        var v = GhosttyTerminalScrollViewport()
        v.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        v.value.delta = delta
        scroll(v)
    }

    /// Moves one OSC 133 semantic prompt relative to the viewport top.
    /// Returns whether the engine moved; absent markers and alternate screens
    /// naturally return false. This changes only this mirror's viewport.
    @discardableResult
    func scrollPrompt(previous: Bool) -> Bool {
        var before = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &before) == GHOSTTY_SUCCESS else { return false }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA_PROMPT
        behavior.value.delta_prompt = previous ? -1 : 1
        scroll(behavior)
        var after = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &after) == GHOSTTY_SUCCESS else { return false }
        return before.offset != after.offset
    }

    func scrollToBottom() {
        var v = GhosttyTerminalScrollViewport()
        v.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        scroll(v)
    }

    /// Whether a DEC private mode (`ansi: false`) or ANSI mode is set.
    func mode(_ number: UInt16, ansi: Bool = false) -> Bool {
        var m = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, ansi), value: false)
        ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_MODE, &m)
        return m.value
    }
}

/// A terminal's size in cells and the pixel size of one cell, as the PTY and
/// libghostty-vt need it.
struct GridSize: Equatable {
    var cols: UInt16
    var rows: UInt16
    var cellWidth: UInt32
    var cellHeight: UInt32
}
