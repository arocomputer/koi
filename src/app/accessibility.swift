import AppKit
import GhosttyVt

/// A lazily requested AX document, in UTF-16 and physical terminal rows.
/// Rendering never builds this document. Grid refs are consumed synchronously
/// here; none survive a terminal mutation. IME text belongs to NSTextInputClient.
struct TerminalAccessibilityText {
    let text: NSString
    let lines: [NSRange]
    let visible: NSRange
    let viewportRow: Int
    let cursorLine: Int
    let selectedRange: NSRange
    let selectedText: String

    init(_ terminal: VTTerminal?) {
        guard let terminal else {
            text = ""; lines = []; visible = NSRange(location: 0, length: 0)
            viewportRow = 0; cursorLine = 0
            selectedRange = NSRange(location: NSNotFound, length: 0); selectedText = ""
            return
        }
        var total = 0
        ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
        // The formatter trims the last blank rows. Keep them in the AX
        // coordinate space, including an empty shell's insertion point.
        var rows = terminal.text().components(separatedBy: "\n")
        if rows.count < total { rows += Array(repeating: "", count: total - rows.count) }
        let cursorRow = max(0, total - Int(terminal.size.rows)) + Int(terminal.cursor.y)
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        var start = GhosttyPointCoordinate(), end = GhosttyPointCoordinate()
        let linearSelection = ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
            && !selection.rectangle
            && ghostty_terminal_point_from_grid_ref(terminal.raw, &selection.start, GHOSTTY_POINT_TAG_SCREEN, &start) == GHOSTTY_SUCCESS
            && ghostty_terminal_point_from_grid_ref(terminal.raw, &selection.end, GHOSTTY_POINT_TAG_SCREEN, &end) == GHOSTTY_SUCCESS
        if linearSelection, (start.y, start.x) > (end.y, end.x) { swap(&start, &end) }

        // Formatting trims spaces, but insertion points and selected blank
        // cells still need addresses in the document.
        let cursorColumn = Int(terminal.cursor.x) + (terminal.cursorPendingWrap ? 1 : 0)
        var required = [(cursorRow, cursorColumn)]
        if linearSelection { required += [(Int(start.y), Int(start.x)), (Int(end.y), Int(end.x) + 1)] }
        for (row, column) in required where rows.indices.contains(row) {
            let missing = Self.columnOffset(terminal, row: row, column: column) - (rows[row] as NSString).length
            if missing > 0 { rows[row] += String(repeating: " ", count: missing) }
        }
        let document = rows.joined(separator: "\n") as NSString
        var ranges: [NSRange] = [], offset = 0
        for row in rows {
            let length = (row as NSString).length
            ranges.append(NSRange(location: offset, length: length))
            offset += length + 1
        }
        text = document
        lines = ranges
        var scrollbar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar)
        viewportRow = Int(scrollbar.offset)
        let top = min(viewportRow, ranges.count - 1)
        let bottom = min(top + Int(terminal.size.rows) - 1, ranges.count - 1)
        visible = NSRange(location: ranges[top].location,
                          length: NSMaxRange(ranges[bottom]) - ranges[top].location)
        cursorLine = cursorRow
        selectedText = terminal.selectedText() ?? ""

        // Convert actual selection endpoints, never search for its text:
        // identical output can occur many times in scrollback.
        if linearSelection {
            let first = Self.offset(terminal, ranges, row: Int(start.y), column: Int(start.x))
            let last = Self.offset(terminal, ranges, row: Int(end.y), column: Int(end.x) + 1)
            selectedRange = NSRange(location: first, length: max(0, last - first))
        } else if terminal.hasSelection {
            selectedRange = NSRange(location: NSNotFound, length: 0)
        } else {
            selectedRange = NSRange(location: Self.offset(terminal, ranges, row: cursorLine,
                                                         column: cursorColumn), length: 0)
        }
    }

    /// AX indices count UTF-16 units; wide-cell spacers contribute no text.
    private static func offset(_ terminal: VTTerminal, _ lines: [NSRange], row: Int, column: Int) -> Int {
        guard lines.indices.contains(row) else { return NSNotFound }
        return lines[row].location + min(columnOffset(terminal, row: row, column: column), lines[row].length)
    }

    /// UTF-16 width in one physical cell; spacers never duplicate wide glyphs.
    private static func cellLength(_ terminal: VTTerminal, row: Int, column: Int) -> Int {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(column), y: UInt32(row))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(terminal.raw, point, &ref) == GHOSTTY_SUCCESS else { return 0 }
        var cell = GhosttyCell(), wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_grid_ref_cell(&ref, &cell)
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { return 0 }
        var scalars = [UInt32](repeating: 0, count: 16), length = 0
        if ghostty_grid_ref_graphemes(&ref, &scalars, scalars.count, &length) == GHOSTTY_OUT_OF_SPACE {
            scalars = [UInt32](repeating: 0, count: length)
            ghostty_grid_ref_graphemes(&ref, &scalars, scalars.count, &length)
        }
        return length == 0 ? 1 : scalars.prefix(length).reduce(0) { $0 + ($1 > 0xffff ? 2 : 1) }
    }

    private static func columnOffset(_ terminal: VTTerminal, row: Int, column: Int) -> Int {
        (0..<min(column, Int(terminal.size.cols))).reduce(0) { $0 + cellLength(terminal, row: row, column: $1) }
    }

    /// The physical column containing an AX index, or its trailing boundary.
    func column(for index: Int, row: Int, terminal: VTTerminal, trailing: Bool = false) -> Int {
        guard lines.indices.contains(row) else { return 0 }
        let target = max(0, index - lines[row].location)
        var count = 0
        for col in 0..<Int(terminal.size.cols) {
            let length = Self.cellLength(terminal, row: row, column: col)
            if length > 0, trailing ? count >= target : count + length > target { return col }
            count += length
        }
        return Int(terminal.size.cols)
    }

    /// Map a visible cell to its text grapheme, including a wide glyph's tail.
    func range(row: Int, column: Int, terminal: VTTerminal) -> NSRange {
        guard lines.indices.contains(row), column >= 0, column < terminal.size.cols else {
            return NSRange(location: NSNotFound, length: 0)
        }
        var start = Self.offset(terminal, lines, row: row, column: column)
        let end = Self.offset(terminal, lines, row: row, column: column + 1)
        if start == end, column > 0,
           Self.cellLength(terminal, row: row, column: column) == 0 {
            start = Self.offset(terminal, lines, row: row, column: column - 1)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Reject invalid client ranges without integer overflow or clamping them
    /// into unrelated text. Empty ranges at the end of the document are valid.
    func contains(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && range.location <= text.length && range.length <= text.length - range.location
    }

    /// Physical row containing an index, including the insertion point at EOF.
    func line(for index: Int) -> Int {
        guard index >= 0, index <= text.length, !lines.isEmpty else { return NSNotFound }
        var low = 0, high = lines.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lines[middle].location <= index { low = middle } else { high = middle }
        }
        return low
    }
}
