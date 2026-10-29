import GhosttyVt
import SwiftUI

/// Fixed app and terminal colors shared by rendering, chrome and color queries.
struct Theme: Sendable {
    let foreground: GhosttyColorRgb
    let background: GhosttyColorRgb
    let cursor: GhosttyColorRgb

    static let current = Theme(
        foreground: .init(r: 0xe6, g: 0xe6, b: 0xea),
        background: .init(r: 0x17, g: 0x17, b: 0x1b),
        cursor: .init(r: 0xe6, g: 0xe6, b: 0xea)
    )

    /// SwiftUI colors keep chrome and previews consistent with terminal rendering.
    var backgroundColor: Color { Self.color(background) }
    var foregroundColor: Color { Self.color(foreground) }
    var cursorColor: Color { Self.color(cursor) }

    /// Converts native 8-bit channels without changing their sRGB color space.
    private static func color(_ rgb: GhosttyColorRgb) -> Color {
        Color(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    /// Sets terminal default colors for rendering and color-query responses.
    func apply(to terminal: GhosttyTerminal) {
        var fg = foreground, bg = background, cur = cursor
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cur)
    }
}
