import AppKit
import Testing
@testable import Koi

/// Every program in programs.json must be complete and have its logo, so a
/// contribution that is missing something fails here rather than showing
/// a blank tile.
@Suite @MainActor struct ProgramsTests {
    @Test func everyProgramHasItsStyleAndLogo() {
        let entries = Programs.entries
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(entry.style != nil, "\(entry.name) has a glyph and two colors")
            #expect(!entry.runs.isEmpty, "\(entry.name) names what it runs as")
            for alias in entry.runs { #expect(Programs.style(for: alias, shell: "zsh").name == entry.name) }
            for symbol in [entry.symbol, entry.mark?.symbol].compactMap({ $0 }) {
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(entry.name): unknown SF Symbol \(symbol)")
            }
            if let logo = entry.logo { #expect(Programs.logo(logo) != nil, "\(entry.name) has logos/\(logo).svg") }
        }
        #expect(Programs.style(for: "claude", shell: "zsh").name == "Claude Code")
        #expect(Programs.style(for: "python3", shell: "zsh").name == "Python")
        #expect(Programs.style(for: "opencode", shell: "zsh").name == "OpenCode")
        #expect(Programs.style(for: "/opt/bin/OpenCode", shell: "zsh").name == "OpenCode")
    }

    @Test func unknownApplicationsKeepThePromptMarkAndTheirOwnName() {
        for name in ["custom-agent", "/opt/bin/MyTool"] {
            let style = Programs.style(for: name, shell: "zsh")
            #expect(style.name == name)
            guard case .text(let glyph) = style.glyph else { Issue.record("Unknown app should use the prompt mark"); continue }
            #expect(glyph == ">_")
        }
    }
}
