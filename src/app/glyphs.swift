import AppKit
import CoreText
import Metal

/// The terminal font at one size and scale, and the cell it defines. All
/// sizes are in device pixels.
struct FontMetrics {
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let cellWidth: Int
    let cellHeight: Int
    /// Extra vertical padding from line-height; never scales the glyphs themselves.
    let lineSpacing: CGFloat
    /// Distance from the cell's bottom to the baseline.
    let descent: CGFloat
    /// Font leading plus configured line spacing, split above and below the glyph
    /// box; the block cursor stays the same height as spacing grows.
    let leading: CGFloat
    let underlinePosition: CGFloat
    let lineThickness: CGFloat

    /// Measures the configured font; line-height adds symmetric cell padding.
    /// The optional multiplier lets offscreen callers measure without global edits.
    init(size points: CGFloat, scale: CGFloat, lineHeight: Double? = nil) {
        let points = points.isFinite ? min(max(points, CGFloat(Config.fontSizeRange.lowerBound)), CGFloat(Config.fontSizeRange.upperBound)) : 13
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let multiplier = lineHeight ?? Config.current.lineHeight
        let height = multiplier.isFinite ? min(max(multiplier, Config.lineHeightRange.lowerBound), Config.lineHeightRange.upperBound) : 1
        let px = points * scale
        // A named family from the config, or the system monospaced font.
        let base: CTFont
        let boldFont: CTFont
        if let family = Config.current.fontFamily, let named = NSFont(name: family, size: px) {
            base = named as CTFont
            boldFont = (NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)) as CTFont
        } else {
            base = NSFont.monospacedSystemFont(ofSize: px, weight: .regular) as CTFont
            boldFont = NSFont.monospacedSystemFont(ofSize: px, weight: .bold) as CTFont
        }
        regular = base
        bold = boldFont
        italic = CTFontCreateCopyWithSymbolicTraits(base, px, nil, .traitItalic, .traitItalic) ?? base
        boldItalic = CTFontCreateCopyWithSymbolicTraits(boldFont, px, nil, .traitItalic, .traitItalic) ?? boldFont

        var glyph = CGGlyph(0)
        var m: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(base, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(base), desc = CTFontGetDescent(base), leading = CTFontGetLeading(base)
        cellWidth = max(1, Int(advance.width.rounded()))
        let normalHeight = max(1, Int((ascent + desc + leading).rounded(.up)))
        cellHeight = max(normalHeight, Int((Double(normalHeight) * height).rounded(.up)))
        lineSpacing = CGFloat(cellHeight - normalHeight)
        descent = (desc + leading / 2).rounded() + (lineSpacing / 2).rounded()
        self.leading = leading.rounded() + lineSpacing
        underlinePosition = max(1, (descent + CTFontGetUnderlinePosition(base)).rounded())
        lineThickness = max(1, CTFontGetUnderlineThickness(base).rounded())
    }

    /// Selects a measured face; missing italic traits retain the original font.
    func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }
}

/// A texture of rasterized glyphs. Each entry is a grapheme cluster drawn by
/// Core Text (which picks fallback fonts, emoji included) into a box one or
/// two cells wide plus padding for overhang, so the renderer places it at
/// the cell's origin and never measures anything per frame.
final class GlyphAtlas {
    struct Entry {
        var x: UInt16, y: UInt16, width: UInt16, height: UInt16
        /// Color glyphs (emoji) are drawn as they are; others are masks
        /// tinted with the cell's foreground.
        var colored: Bool
    }

    struct Key: Hashable {
        var text: String
        var bold: Bool
        var italic: Bool
        var wide: Bool
    }

    /// Replaced, never rewritten, when the atlas starts over, so frames still
    /// in flight keep sampling the texture they were encoded with.
    private(set) var texture: MTLTexture
    private let device: MTLDevice
    let metrics: FontMetrics
    let pad: Int
    private let size: Int
    private var assemblingFrame = false
    private(set) var overflowed = false
    private var entries: [Key: Entry] = [:]
    private var penX = 0, penY = 0, rowHeight = 0
    private let context: CGContext
    /// Bumped when the atlas fills and starts over; cached instances that
    /// point into it must be rebuilt.
    private(set) var generation = 0

    init(device: MTLDevice, metrics: FontMetrics, size: Int = 2048) {
        precondition(size > 0 && size <= Int(UInt16.max))
        self.size = size
        self.device = device
        self.metrics = metrics
        pad = max(2, metrics.cellWidth / 2)
        texture = Self.makeTexture(device, size)
        let w = metrics.cellWidth * 2 + pad * 2, h = metrics.cellHeight + pad * 2
        context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setAllowsFontSmoothing(false)
        context.setShouldAntialias(true)
    }

    private static func makeTexture(_ device: MTLDevice, _ size: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)!
    }

    /// Pins this generation while rows, predictions and cursor quads are assembled.
    /// A full atlas reports overflow instead of invalidating earlier UVs.
    func beginFrame() {
        precondition(!assemblingFrame)
        assemblingFrame = true
        overflowed = false
    }

    /// Releases the assembly pin; submitted GPU commands retain their texture.
    func endFrame() { assemblingFrame = false }

    /// The entry for `key`, rasterizing it on first use; nil if it cannot fit.
    func entry(_ key: Key) -> Entry? {
        if let e = entries[key] { return e }
        guard let e = rasterize(key) else { return nil }
        entries[key] = e
        return e
    }

    private func rasterize(_ key: Key) -> Entry? {
        let cells = key.wide ? 2 : 1
        let w = metrics.cellWidth * cells + pad * 2, h = metrics.cellHeight + pad * 2
        context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let cell = CGRect(x: pad, y: pad, width: metrics.cellWidth * cells, height: metrics.cellHeight)
        if key.text.unicodeScalars.count == 1, let s = key.text.unicodeScalars.first,
           BoxDrawing.draw(s, in: cell, context: context, thickness: metrics.lineThickness) {
            return store(w, h, colored: false, key)
        }

        let font = metrics.font(bold: key.bold, italic: key.italic)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor.white]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, key.text as CFString, attrs as CFDictionary))
        // Every run inherits the font and color set on the whole attributed
        // string above, so the CF attributes are always present; Swift rejects a
        // conditional downcast between CF types, so these are plain casts.
        let colored = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).contains { run in
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = runAttrs[kCTFontAttributeName] as! CTFont
            return CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
        }
        // Squeeze glyphs that are wider than their cells (some fallback
        // fonts) so they never spill into the neighbors.
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let room = CGFloat(metrics.cellWidth * cells)
        context.saveGState()
        if colored {
            // Emoji fill their cells, centered, as text-sized pictures look
            // lost in a two-cell box.
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let box = CGSize(width: room, height: CGFloat(metrics.cellHeight) - metrics.lineSpacing)
            let s = b.width > 0 && b.height > 0 ? min(box.width / b.width, box.height / b.height) * 0.92 : 1
            context.translateBy(x: CGFloat(pad) + (box.width - b.width * s) / 2 - b.minX * s,
                                y: CGFloat(pad) + metrics.lineSpacing / 2 + (box.height - b.height * s) / 2 - b.minY * s)
            context.scaleBy(x: s, y: s)
        } else {
            context.translateBy(x: CGFloat(pad), y: CGFloat(pad) + metrics.descent)
            if width > room * 1.05 { context.scaleBy(x: room / width, y: room / width) }
        }
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return store(w, h, colored: colored, key)
    }

    /// Copies the drawn box (the bitmap's left `w` x `h`) into the texture.
    private func store(_ w: Int, _ h: Int, colored: Bool, _ key: Key) -> Entry? {
        // An oversized glyph cannot fit even in an empty atlas. Never recurse
        // or evict useful entries trying to accommodate it.
        guard w <= size, h <= size else { return nil }
        guard let place = place(width: w, height: h) else {
            if assemblingFrame {
                overflowed = true
                return nil
            }
            reset()
            return rasterize(key)
        }
        // The bitmap's rows run top-down and it is as tall as every box, so
        // the glyph box is its left w columns.
        texture.replace(region: MTLRegionMake2D(place.x, place.y, w, h), mipmapLevel: 0,
                        withBytes: context.data!, bytesPerRow: context.bytesPerRow)
        return Entry(x: UInt16(place.x), y: UInt16(place.y), width: UInt16(w), height: UInt16(h), colored: colored)
    }

    private func place(width: Int, height: Int) -> (x: Int, y: Int)? {
        if penX + width > size {
            penX = 0
            penY += rowHeight
            rowHeight = 0
        }
        guard penY + height <= size else { return nil }
        defer {
            penX += width
            rowHeight = max(rowHeight, height)
        }
        return (penX, penY)
    }

    /// Evicts cached glyphs between assembly attempts, never within one.
    func reset() {
        precondition(!assemblingFrame)
        texture = Self.makeTexture(device, size)
        entries.removeAll()
        penX = 0; penY = 0; rowHeight = 0
        generation += 1
    }
}
