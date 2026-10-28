import CoreGraphics

/// Draws box-drawing (U+2500–U+257F) and block (U+2580–U+259F) characters
/// from geometry instead of a font, so lines meet across cells and blocks
/// fill them edge to edge whatever the font has.
enum BoxDrawing {
    /// Draws `scalar` filling `cell` (CoreGraphics coordinates, y up) in
    /// white; false if it is not one of these characters.
    static func draw(_ scalar: Unicode.Scalar, in cell: CGRect, context: CGContext, thickness: CGFloat) -> Bool {
        let v = scalar.value
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor.white)
        context.setStrokeColor(CGColor.white)
        // Straight lines and blocks land on whole pixels; only arcs need
        // antialiasing.
        context.setShouldAntialias((0x256D...0x2570).contains(v))
        if (0x2580...0x259F).contains(v) {
            block(v, cell, context)
            return true
        }
        if (0x256D...0x2570).contains(v) {
            arc(v, cell, context, thickness)
            return true
        }
        guard (0x2500...0x257F).contains(v), let a = arms[v] else { return false }
        lines(a, cell, context, thickness)
        return true
    }

    /// Up, right, down, left: 0 none, 1 light, 2 heavy, 3 double.
    private typealias Arms = (UInt8, UInt8, UInt8, UInt8)

    private static let arms: [UInt32: Arms] = {
        let table: [(UInt32, String)] = [
            (0x2500, "0101"), (0x2501, "0202"), (0x2502, "1010"), (0x2503, "2020"),
            (0x2504, "0101"), (0x2505, "0202"), (0x2506, "1010"), (0x2507, "2020"),
            (0x2508, "0101"), (0x2509, "0202"), (0x250A, "1010"), (0x250B, "2020"),
            (0x250C, "0110"), (0x250D, "0210"), (0x250E, "0120"), (0x250F, "0220"),
            (0x2510, "0011"), (0x2511, "0012"), (0x2512, "0021"), (0x2513, "0022"),
            (0x2514, "1100"), (0x2515, "1200"), (0x2516, "2100"), (0x2517, "2200"),
            (0x2518, "1001"), (0x2519, "1002"), (0x251A, "2001"), (0x251B, "2002"),
            (0x251C, "1110"), (0x251D, "1210"), (0x251E, "2110"), (0x251F, "1120"),
            (0x2520, "2120"), (0x2521, "2210"), (0x2522, "1220"), (0x2523, "2220"),
            (0x2524, "1011"), (0x2525, "1012"), (0x2526, "2011"), (0x2527, "1021"),
            (0x2528, "2021"), (0x2529, "2012"), (0x252A, "1022"), (0x252B, "2022"),
            (0x252C, "0111"), (0x252D, "0112"), (0x252E, "0211"), (0x252F, "0212"),
            (0x2530, "0121"), (0x2531, "0122"), (0x2532, "0221"), (0x2533, "0222"),
            (0x2534, "1101"), (0x2535, "1102"), (0x2536, "1201"), (0x2537, "1202"),
            (0x2538, "2101"), (0x2539, "2102"), (0x253A, "2201"), (0x253B, "2202"),
            (0x253C, "1111"), (0x253D, "1112"), (0x253E, "1211"), (0x253F, "1212"),
            (0x2540, "2111"), (0x2541, "1121"), (0x2542, "2121"), (0x2543, "2112"),
            (0x2544, "2211"), (0x2545, "1122"), (0x2546, "1221"), (0x2547, "2212"),
            (0x2548, "1222"), (0x2549, "2122"), (0x254A, "2221"), (0x254B, "2222"),
            (0x254C, "0101"), (0x254D, "0202"), (0x254E, "1010"), (0x254F, "2020"),
            (0x2550, "0303"), (0x2551, "3030"), (0x2552, "0310"), (0x2553, "0130"),
            (0x2554, "0330"), (0x2555, "0013"), (0x2556, "0031"), (0x2557, "0033"),
            (0x2558, "1300"), (0x2559, "3100"), (0x255A, "3300"), (0x255B, "1003"),
            (0x255C, "3001"), (0x255D, "3003"), (0x255E, "1310"), (0x255F, "3130"),
            (0x2560, "3330"), (0x2561, "1013"), (0x2562, "3031"), (0x2563, "3033"),
            (0x2564, "0313"), (0x2565, "0131"), (0x2566, "0333"), (0x2567, "1303"),
            (0x2568, "3101"), (0x2569, "3303"), (0x256A, "1313"), (0x256B, "3131"),
            (0x256C, "3333"),
            (0x2574, "0001"), (0x2575, "1000"), (0x2576, "0100"), (0x2577, "0010"),
            (0x2578, "0002"), (0x2579, "2000"), (0x257A, "0200"), (0x257B, "0020"),
            (0x257C, "0201"), (0x257D, "1020"), (0x257E, "0102"), (0x257F, "2010"),
        ]
        var out: [UInt32: Arms] = [:]
        for (v, s) in table {
            let d = s.utf8.map { $0 - 48 }
            out[v] = (d[0], d[1], d[2], d[3])
        }
        return out
    }()

    private static func lines(_ a: Arms, _ c: CGRect, _ ctx: CGContext, _ t: CGFloat) {
        let light = max(1, t.rounded()), heavy = light * 2, gap = light
        func width(_ w: UInt8) -> CGFloat { w == 2 ? heavy : w == 3 ? light * 3 : light }
        let cx = (c.midX - light / 2).rounded() + light / 2, cy = (c.midY - light / 2).rounded() + light / 2
        // Arms reach past the center by half the widest crossing arm, so
        // corners and tees close.
        let vertical = max(a.0 == 0 ? 0 : width(a.0), a.2 == 0 ? 0 : width(a.2))
        let horizontal = max(a.1 == 0 ? 0 : width(a.1), a.3 == 0 ? 0 : width(a.3))

        // Up and down are vertical bars; left and right horizontal ones. A
        // double line is two light ones a light line's width apart.
        func vbar(_ w: UInt8, from y0: CGFloat, to y1: CGFloat) {
            guard w != 0 else { return }
            if w == 3 {
                for dx in [-(gap + light) / 2 - light / 2, (gap + light) / 2 - light / 2] {
                    ctx.fill(CGRect(x: cx + dx, y: min(y0, y1), width: light, height: abs(y1 - y0)))
                }
            } else {
                let lw = width(w)
                ctx.fill(CGRect(x: cx - lw / 2, y: min(y0, y1), width: lw, height: abs(y1 - y0)))
            }
        }
        func hbar(_ w: UInt8, from x0: CGFloat, to x1: CGFloat) {
            guard w != 0 else { return }
            if w == 3 {
                for dy in [-(gap + light) / 2 - light / 2, (gap + light) / 2 - light / 2] {
                    ctx.fill(CGRect(x: min(x0, x1), y: cy + dy, width: abs(x1 - x0), height: light))
                }
            } else {
                let lw = width(w)
                ctx.fill(CGRect(x: min(x0, x1), y: cy - lw / 2, width: abs(x1 - x0), height: lw))
            }
        }
        vbar(a.0, from: c.maxY, to: cy - horizontal / 2)
        vbar(a.2, from: c.minY, to: cy + horizontal / 2)
        hbar(a.1, from: c.maxX, to: cx - vertical / 2)
        hbar(a.3, from: c.minX, to: cx + vertical / 2)
    }

    private static func arc(_ v: UInt32, _ c: CGRect, _ ctx: CGContext, _ t: CGFloat) {
        let light = max(1, t.rounded())
        let cx = (c.midX - light / 2).rounded() + light / 2, cy = (c.midY - light / 2).rounded() + light / 2
        // Each rounded corner joins two edge midpoints through the center.
        let (p0, p1): (CGPoint, CGPoint) = switch v {
        case 0x256D: (CGPoint(x: c.maxX, y: cy), CGPoint(x: cx, y: c.minY)) // ╭ right and down
        case 0x256E: (CGPoint(x: c.minX, y: cy), CGPoint(x: cx, y: c.minY)) // ╮ left and down
        case 0x256F: (CGPoint(x: c.minX, y: cy), CGPoint(x: cx, y: c.maxY)) // ╯ left and up
        default: (CGPoint(x: c.maxX, y: cy), CGPoint(x: cx, y: c.maxY))     // ╰ right and up
        }
        ctx.setLineWidth(light)
        ctx.setLineCap(.butt)
        ctx.move(to: p0)
        ctx.addQuadCurve(to: p1, control: CGPoint(x: cx, y: cy))
        ctx.strokePath()
    }

    private static func block(_ v: UInt32, _ c: CGRect, _ ctx: CGContext) {
        let w = c.width, h = c.height
        func fill(_ x: CGFloat, _ y: CGFloat, _ fw: CGFloat, _ fh: CGFloat, alpha: CGFloat = 1) {
            ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
            ctx.fill(CGRect(x: c.minX + (x * w).rounded(), y: c.minY + (y * h).rounded(),
                            width: (fw * w).rounded(), height: (fh * h).rounded()))
        }
        switch v {
        case 0x2580: fill(0, 0.5, 1, 0.5)
        case 0x2581...0x2587: fill(0, 0, 1, CGFloat(v - 0x2580) / 8)
        case 0x2588: fill(0, 0, 1, 1)
        case 0x2589...0x258F: fill(0, 0, CGFloat(0x2590 - v) / 8, 1)
        case 0x2590: fill(0.5, 0, 0.5, 1)
        case 0x2591: fill(0, 0, 1, 1, alpha: 0.25)
        case 0x2592: fill(0, 0, 1, 1, alpha: 0.5)
        case 0x2593: fill(0, 0, 1, 1, alpha: 0.75)
        case 0x2594: fill(0, 7.0 / 8, 1, 1.0 / 8)
        case 0x2595: fill(7.0 / 8, 0, 1.0 / 8, 1)
        default:
            // Quadrants: upper left, upper right, lower left, lower right.
            let quads: [UInt32: (Bool, Bool, Bool, Bool)] = [
                0x2596: (false, false, true, false), 0x2597: (false, false, false, true),
                0x2598: (true, false, false, false), 0x2599: (true, false, true, true),
                0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                0x259C: (true, true, false, true), 0x259D: (false, true, false, false),
                0x259E: (false, true, true, false), 0x259F: (false, true, true, true),
            ]
            guard let q = quads[v] else { return }
            if q.0 { fill(0, 0.5, 0.5, 0.5) }
            if q.1 { fill(0.5, 0.5, 0.5, 0.5) }
            if q.2 { fill(0, 0, 0.5, 0.5) }
            if q.3 { fill(0.5, 0, 0.5, 0.5) }
        }
        ctx.setFillColor(CGColor.white)
    }
}
