import AppKit

/// Draws uncommitted IME text above the terminal without changing PTY state.
/// TextKit supplies Unicode shaping, wrapping and candidate-window geometry;
/// this view never takes focus or handles pointer events.
@MainActor final class CompositionView: NSView {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var origin = NSPoint.zero
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var caretRect = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Release the finished composition's text and layout without moving focus.
    func clear() {
        isHidden = true
        if storage.length > 0 { storage.setAttributedString(NSAttributedString(string: "")) }
        selection = NSRange(location: 0, length: 0)
        caretRect = .zero
    }

    /// Refresh after marked text, cursor, font or grid geometry changes.
    func update(_ text: NSAttributedString, selected: NSRange, font: NSFont,
                cell: NSSize, grid: NSSize, cursor: NSPoint,
                foreground: NSColor, background: NSColor) {
        isHidden = text.length == 0 || grid.width <= 0 || grid.height <= 0
        guard !isHidden else {
            clear()
            return
        }
        let display = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = cell.height
        paragraph.maximumLineHeight = cell.height
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.firstLineHeadIndent = min(max(0, cursor.x * cell.width), max(0, grid.width - cell.width))
        paragraph.defaultTabInterval = cell.width * 8
        display.addAttributes([.font: font, .foregroundColor: foreground, .backgroundColor: background,
                               .underlineStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: paragraph],
                              range: NSRange(location: 0, length: display.length))
        selection = Self.clamp(selected, length: display.length)
        if selection.length > 0 {
            selection = (display.string as NSString).rangeOfComposedCharacterSequences(for: selection)
            display.addAttributes([.backgroundColor: NSColor.selectedTextBackgroundColor,
                                   .foregroundColor: NSColor.selectedTextColor], range: selection)
        }
        storage.setAttributedString(display)
        container.containerSize = NSSize(width: grid.width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        // Keep a wrapped composition visible even at the bottom of a pane.
        origin = NSPoint(x: 0, y: max(0, min(cursor.y * cell.height, grid.height - used.height)))
        caretRect = rect(for: NSRange(location: NSMaxRange(selection), length: 0), cellHeight: cell.height)
        if caretRect.maxY > grid.height {
            origin.y -= caretRect.maxY - grid.height
            caretRect = rect(for: NSRange(location: NSMaxRange(selection), length: 0), cellHeight: cell.height)
        }
        needsDisplay = true
    }

    /// A bounded UTF-16 range is used for both IME queries and TextKit access.
    static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let start = range.location == NSNotFound ? length : min(max(0, range.location), length)
        return NSRange(location: start, length: min(max(0, range.length), length - start))
    }

    /// Candidate rectangles follow the composing caret, including soft wraps.
    func rect(for range: NSRange, cellHeight: CGFloat) -> NSRect {
        guard storage.length > 0 else { return .zero }
        let bounded = Self.clamp(range, length: storage.length)
        if bounded.location == storage.length {
            if manager.extraLineFragmentTextContainer != nil {
                let extra = manager.extraLineFragmentRect
                return NSRect(x: extra.minX + origin.x, y: extra.minY + origin.y, width: 1, height: cellHeight)
            }
            let glyph = manager.glyphIndexForCharacter(at: storage.length - 1)
            let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return NSRect(x: box.maxX + origin.x, y: box.minY + origin.y, width: 1, height: cellHeight)
        }
        let glyphs = manager.glyphRange(forCharacterRange: bounded.length > 0 ? bounded :
            NSRange(location: bounded.location, length: 1), actualCharacterRange: nil)
        let box = manager.boundingRect(forGlyphRange: glyphs, in: container)
        return NSRect(x: box.minX + origin.x, y: box.minY + origin.y,
                      width: bounded.length == 0 ? 1 : max(1, box.width), height: max(cellHeight, box.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        if selection.length == 0 {
            NSColor.labelColor.setFill()
            caretRect.fill()
        }
    }
}
