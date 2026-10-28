import Foundation
import Testing
@testable import Koi

/// Reports are tested as allowlisted text; no real logs, configuration or pasteboard are read.
@Suite struct DiagnosticsTests {
    /// Credentials, hosts, addresses and long tokens go, including inside
    /// paths; labels, versions and short alias lookalikes stay.
    @Test func redactionRemovesSecretsAndHostsButKeepsLabelsAndVersions() {
        let input = "token=short-secret password:hunter2 sk-fixtureSecret user@host.internal 192.168.1.7 2001:db8::1 private.example"
        let text = Diagnostics.redact(input)
        for sensitive in ["short-secret", "hunter2", "sk-fixtureSecret", "host.internal", "192.168.1.7", "2001:db8::1", "private.example"] {
            #expect(!text.contains(sensitive))
        }
        let aliased = Diagnostics.redact("App version: 0.1.0\nDevice: Apple GPU\n/hosts/a/config\n/hosts/1/config", sensitiveHosts: ["a", "1"])
        #expect(aliased.contains("App version: 0.1.0") && aliased.contains("Device: Apple GPU"))
        #expect(aliased.contains("/hosts/[host]/config"))
        let fingerprint = String(repeating: "0123456789abcdef", count: 4)
        #expect(!Diagnostics.redact("0.1.0+\(fingerprint)").contains(fingerprint))
        #expect(!Diagnostics.redact(fingerprint).contains(fingerprint))
    }

    /// The report shows what the coordinator supplied, never inventing a server
    /// version from the app's; every field is scrubbed except a well-formed
    /// build fingerprint in the server-version line, and only when it contains
    /// no configured alias.
    @Test func reportUsesSuppliedFactsAndScrubsEverythingButAValidBuildFingerprint() throws {
        var report = fixture
        report.appVersion = "9.2"
        report.appBuild = "42"
        #expect(report.text.contains("App version: 9.2") && report.text.contains("App build: 42"))
        #expect(report.text.contains("Server version: unknown (not supplied)"))
        #expect(report.text.contains("Server checked at: unknown (not supplied)"))

        report.server.version = "0.8.1"
        report.server.wireVersion = 6
        report.server.checkedAt = Date(timeIntervalSince1970: 0)
        report.server.sensitiveHosts = ["private-alias"]
        report.stateURL = URL(fileURLWithPath: "/fixture/home/state/private-alias/ghp_fixtureCredential1234567890")
        report.renderingSummary = ["Frames: 4; token=fixture-secret"]
        report.recentIssueSummary = ["Connection error user@host.internal password:hunter2"]
        #expect(report.text.contains("Server version: 0.8.1") && report.text.contains("Server wire version: 6"))
        #expect(report.text.contains("Server build matches this Koi: unknown"))
        report.server.bundledVersion = "0.8.2"
        #expect(report.text.contains("Server build matches this Koi: no (restart the server to update it)"))
        report.server.bundledVersion = "0.8.1"
        #expect(report.text.contains("Server build matches this Koi: yes"))
        #expect(report.text.contains("First pane ready: unknown"))
        report.launchToFirstPaneMS = 412
        #expect(report.text.contains("First pane ready: 412 ms after launch"))
        #expect(report.text.contains("Server checked at: 1970-01-01T00:00:00Z"))
        #expect(report.text.contains("Transport: SSH relay") && report.text.contains("Config path: ~/.config/koi/config"))
        #expect(report.text.contains("Frames: 4"))
        for sensitive in ["private-alias", "ghp_fixtureCredential1234567890", "/fixture/home", "fixture-secret", "hunter2", "host.internal"] {
            #expect(!report.text.contains(sensitive))
        }

        let fingerprint = String(repeating: "0123456789abcdef", count: 4)
        let identity = "0.1.0+\(fingerprint)"
        report = fixture
        report.server.version = identity
        report.appVersion = identity
        report.appBuild = fingerprint
        report.stateURL = URL(fileURLWithPath: "/fixture/home/\(identity)")
        report.server.logURL = URL(fileURLWithPath: "/tmp/\(fingerprint)/server.log")
        #expect(report.text.contains("Server version: \(identity)\n"))
        let otherFields = report.text.split(separator: "\n").filter { !$0.hasPrefix("Server version:") }
        #expect(otherFields.allSatisfy { !$0.contains(fingerprint) })
        report.server.sensitiveHosts = [fingerprint]
        #expect(!report.text.contains(fingerprint))

        let malformed = String(repeating: "abcdef0123456789", count: 4)
        for version in ["0.1.0+\(malformed.dropLast())", "0.1.0+\(malformed)f", "0.1.0+\(malformed.dropLast())g",
                        "01.1.0+\(malformed)", "0.1+\(malformed)", "v0.1.0+\(malformed)", "0.1.0+\(malformed)\n",
                        " 0.1.0+\(malformed)", "0.1.0+\(malformed) password:hunter2", "token=\(malformed)", "0.1.0+ghp_\(malformed)"] {
            var report = fixture
            report.server.version = version
            let text = report.text
            #expect(!text.contains(String(malformed.prefix(40))) && !text.contains("hunter2") && !text.contains("ghp_"))
        }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("koi-diagnostics-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try report.exportFromUserAction(to: destination)
        #expect(try String(contentsOf: destination, encoding: .utf8) == report.text)
        #expect(throws: (any Error).self) { try report.exportFromUserAction(to: URL(string: "https://example.test/report")!) }
    }

    private var fixture: Diagnostics {
        Diagnostics(server: .init(transport: .sshRelay, connected: true),
                    configURL: URL(fileURLWithPath: "/fixture/home/.config/koi/config"),
                    stateURL: URL(fileURLWithPath: "/fixture/home/.local/state/koi"),
                    logURL: URL(fileURLWithPath: "/fixture/home/.local/state/koi/server.log"),
                    configIssueCount: 2, homeURL: URL(fileURLWithPath: "/fixture/home"))
    }
}

/// Issue history fixtures use only local values and never attach to application state.
@Suite @MainActor struct DiagnosticIssuesTests {
    @Test func historyIsBoundedAndNonpositiveCapacityStoresNothing() {
        let issues = DiagnosticIssues(capacity: 2)
        for message in ["First", "Second", "Third"] { issues.record(subsystem: "server", message: message) }
        #expect(issues.entries.map(\.message) == ["Third", "Second"])
        let defaulted = DiagnosticIssues()
        for index in 0..<101 { defaulted.record(subsystem: "server", message: "Issue \(index)") }
        #expect(defaulted.entries.count == 100)
        #expect(defaulted.entries.first?.message == "Issue 100" && defaulted.entries.last?.message == "Issue 1")
        for capacity in [0, -1] {
            let disabled = DiagnosticIssues(capacity: capacity)
            disabled.record(subsystem: "server", message: "Unavailable")
            #expect(disabled.entries.isEmpty)
        }
    }

    @Test func repeatsRetainIdentityAndFirstSeenAndMoveToTheFront() throws {
        let issues = DiagnosticIssues(capacity: 2)
        let firstSeen = Date(timeIntervalSince1970: 10)
        let lastSeen = Date(timeIntervalSince1970: 20)
        issues.record(subsystem: "server", message: "Unavailable", at: firstSeen)
        let original = try #require(issues.entries.first)
        issues.record(subsystem: "renderer", message: "Unavailable", at: firstSeen)
        issues.record(subsystem: "server", message: "Unavailable", at: lastSeen)
        let repeated = try #require(issues.entries.first)
        #expect(issues.entries.count == 2)
        #expect(repeated.id == original.id && repeated.subsystem == "server")
        #expect(repeated.firstSeen == firstSeen && repeated.lastSeen == lastSeen && repeated.count == 2)
        issues.record(subsystem: "server", message: "Disconnected", at: lastSeen)
        #expect(issues.entries.map(\.message) == ["Disconnected", "Unavailable"])
        #expect(issues.entries.last?.id == original.id)

        issues.clear()
        #expect(issues.entries.isEmpty)
        let nextSeen = Date(timeIntervalSince1970: 50)
        issues.record(subsystem: "server", message: "Unavailable", at: nextSeen)
        let fresh = try #require(issues.entries.first)
        #expect(fresh.id != original.id && fresh.firstSeen == nextSeen && fresh.count == 1)
    }

    /// Scrubbing and truncation happen before deduplication, so two different
    /// secrets collapse into one entry and a cut-off credential cannot escape.
    @Test func summariesAreRedactedTruncatedAndThenDeduplicated() throws {
        let issues = DiagnosticIssues()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let fingerprint = String(repeating: "0123456789abcdef", count: 4)
        issues.record(subsystem: "private-alias password:hunter2",
                      message: "\(home)/cache PRIVATE-ALIAS user@host.internal 192.168.1.7 2001:db8::1 private.example\n"
                        + "token=short-secret sk-fixtureSecret ghp_fixtureCredential1234567890 0.1.0+\(fingerprint)",
                      sensitiveHosts: ["private-alias"])
        let entry = try #require(issues.entries.first)
        let text = entry.subsystem + " " + entry.message
        for sensitive in [home, "private-alias", "PRIVATE-ALIAS", "hunter2", "host.internal", "192.168.1.7", "2001:db8::1",
                          "private.example", "short-secret", "sk-fixtureSecret", "ghp_fixtureCredential1234567890", fingerprint] {
            #expect(!text.contains(sensitive))
        }
        #expect(entry.message.contains("~/cache") && !entry.message.contains("\n"))

        let prefix = String(repeating: "retry ", count: 100)
        issues.record(subsystem: "host-alpha", message: "password:first \(prefix)one", sensitiveHosts: ["host-alpha"])
        let original = try #require(issues.entries.first)
        issues.record(subsystem: "host-beta", message: "password:second \(prefix)two", sensitiveHosts: ["host-beta"])
        #expect(issues.entries.count == 2)
        #expect(issues.entries.first?.id == original.id && issues.entries.first?.count == 2)
        #expect(issues.entries.first?.subsystem == "[host]")
        issues.record(subsystem: "server", message: String(repeating: "retry ", count: 80) + "password:hunter2")
        #expect(issues.entries.first?.message.hasSuffix("[credential]") == true)

        issues.record(subsystem: String(repeating: "🐟", count: 30), message: String(repeating: "🐟", count: 200))
        let unicode = try #require(issues.entries.first)
        #expect(unicode.subsystem == String(repeating: "🐟", count: 12) && unicode.subsystem.utf8.count <= 50)
        #expect(unicode.message == String(repeating: "🐟", count: 125) && unicode.message.utf8.count <= 500)
    }
}
