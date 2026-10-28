import AppKit
import SwiftUI

/// How a program shows in Koi: the name it goes by and the tile drawn for
/// it, a small rounded square in the program's colors with its mark. The
/// programs Koi knows are listed in resources/programs/programs.json.
struct ProgramStyle {
    enum Glyph {
        /// A logo from resources/programs/logos (Simple Icons, CC0).
        case brand(String)
        case symbol(String)
        case text(String)
    }

    var name: String
    var glyph: Glyph
    /// The tile's gradient, top to bottom, and the glyph's color.
    var top: Color
    var bottom: Color
    var ink: Color
    /// The one-color mark in pane headers, when it differs from the tile's
    /// glyph (for example, a plain hexagon for Node).
    var mark: Glyph? = nil
}

enum Programs {
    /// The style of what a pane runs; a pane not yet reported is at a shell prompt.
    static func style(for pane: Wire.PaneInfo?) -> ProgramStyle {
        style(for: pane?.program ?? "", shell: pane?.shell ?? "zsh")
    }

    /// The style for a foreground program, or for the shell at its prompt
    /// when `program` is "".
    static func style(for program: String, shell: String) -> ProgramStyle {
        if program.isEmpty { return shellStyle(shell) }
        if let s = table[program] { return s }
        // Anything else gets its initial on a neutral tile.
        let initial = program.first.map { String($0).uppercased() } ?? "?"
        return ProgramStyle(name: program, glyph: .text(initial), top: hex(0x3B3B42), bottom: hex(0x26262B), ink: hex(0xDADAE0))
    }

    static func shellStyle(_ shell: String) -> ProgramStyle {
        ProgramStyle(name: shell, glyph: .text(">_"), top: hex(0x2F3532), bottom: hex(0x1D2220), ink: hex(0x5CD38C))
    }

    /// An entry of `resources/programs/programs.json`; see CONTRIBUTING.md,
    /// "Program icons", for the resource format.
    struct Entry: Decodable {
        var runs: [String]
        var name: String
        var logo: String?
        var symbol: String?
        var text: String?
        var colors: [String]
        var ink: String?
        var mark: Mark?

        struct Mark: Decodable {
            var symbol: String?
            var text: String?
        }

        var style: ProgramStyle? {
            let glyph: ProgramStyle.Glyph
            if let logo { glyph = .brand(logo) } else if let symbol { glyph = .symbol(symbol) } else if let text { glyph = .text(text) } else { return nil }
            guard colors.count == 2, let top = hex(colors[0]), let bottom = hex(colors[1]), let ink = hex(ink ?? "FFFFFF") else { return nil }
            var mark: ProgramStyle.Glyph?
            if let m = self.mark { mark = m.symbol.map { .symbol($0) } ?? m.text.map { .text($0) } }
            return ProgramStyle(name: name, glyph: glyph, top: top, bottom: bottom, ink: ink, mark: mark)
        }
    }

    /// The entries of programs.json, in order.
    static var entries: [Entry] {
        for dir in directories {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("programs.json")),
               let entries = try? JSONDecoder().decode([Entry].self, from: data) {
                return entries
            }
        }
        return []
    }

    /// Keyed by the name the program runs as.
    static let table: [String: ProgramStyle] = {
        var t: [String: ProgramStyle] = [:]
        for entry in entries {
            guard let style = entry.style else { continue }
            for name in entry.runs { t[name] = style }
        }
        return t
    }()

    /// Program resources: in the app's bundle, or in development and the
    /// tests, in the repository.
    private static let directories: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("programs"),
        Paths.repoRoot?.appendingPathComponent("src/app/resources/programs"),
    ].compactMap { $0 }

    private static func hex(_ s: String) -> Color? {
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return hex(v)
    }

    private static func hex(_ v: Int) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// A logo as a template image, loaded once: from the app's resources, or
    /// in development from the repository.
    @MainActor static func logo(_ name: String) -> NSImage? {
        if let cached = logos[name] { return cached }
        for dir in directories {
            if let image = NSImage(contentsOf: dir.appendingPathComponent("logos/\(name).svg")) {
                image.isTemplate = true
                logos[name] = image
                return image
            }
        }
        return nil
    }
    @MainActor private static var logos: [String: NSImage] = [:]
}

/// A program's tile: its colors as a soft gradient with a hairline highlight
/// along the top, and its mark in the middle.
struct ProgramTile: View {
    let style: ProgramStyle
    /// The tile's height; it is drawn a touch wider than tall, like a little
    /// terminal window.
    var size: CGFloat = 18
    /// The height tab tiles use, the same in the side and top bars.
    static let tabSize: CGFloat = 18
    private var width: CGFloat { (size * 1.14).rounded() }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                               lineWidth: 0.5)
            glyph.foregroundStyle(style.ink)
        }
        .frame(width: width, height: size)
        .shadow(color: .black.opacity(0.3), radius: 0.8, y: 0.5)
    }

    @ViewBuilder private var glyph: some View {
        switch style.glyph {
        case .brand(let name):
            if let image = Programs.logo(name) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: size * 0.6, height: size * 0.6)
            }
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.5, weight: .semibold))
        case .text(let text):
            Text(text)
                .font(.system(size: size * (text.count > 1 ? 0.42 : 0.56), weight: .heavy, design: text.count > 1 ? .monospaced : .rounded))
                .tracking(text.count > 1 ? -0.5 : 0)
        }
    }
}
