import AppKit
import Testing
@testable import Koi

/// Runtime catalog lookup and artwork loading that portable schema checks cannot verify.
@Suite @MainActor struct ProgramsTests {
    @Test func everyProgramHasItsStyleAndLogo() {
        let entries = Programs.entries
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(entry.style != nil, "\(entry.name) has a glyph and two colors")
            for alias in entry.runs {
                #expect(Programs.style(for: alias, shell: "zsh").name == entry.name)
                #expect(Programs.style(for: "/opt/bin/" + alias.uppercased(), shell: "zsh").name == entry.name)
            }
            for symbol in [entry.symbol, entry.mark?.symbol].compactMap({ $0 }) {
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(entry.name): unknown SF Symbol \(symbol)")
            }
            if let logo = entry.logo { #expect(Programs.logo(logo) != nil, "\(entry.name) has logos/\(logo).svg") }
        }
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
