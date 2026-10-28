import Foundation
import Testing
@testable import Koi

/// Every program in programs.json must be complete and have its logo, so a
/// contribution that is missing something fails here rather than showing
/// a blank tile.
@Test @MainActor func everyProgramHasItsStyleAndLogo() {
    let entries = Programs.entries
    #expect(entries.count > 30)
    for entry in entries {
        #expect(entry.style != nil, "\(entry.name) has a glyph and two colors")
        #expect(!entry.runs.isEmpty, "\(entry.name) names what it runs as")
        if let logo = entry.logo { #expect(Programs.logo(logo) != nil, "\(entry.name) has logos/\(logo).svg") }
    }
    #expect(Programs.style(for: "claude", shell: "zsh").name == "Claude Code")
    #expect(Programs.style(for: "python3", shell: "zsh").name == "Python")
}
