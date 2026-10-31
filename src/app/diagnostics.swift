import Foundation
import Observation

/// Explicit server facts from the coordinator, never inferred from the bundled CLI version.
/// Pass transport labels, versions, paths and check timestamps only; exclude logs,
/// commands and terminal text.
struct DiagnosticServer {
    enum Transport: String { case localSocket = "Local socket", encryptedUDP = "Encrypted UDP", sshRelay = "SSH relay", disconnected = "Disconnected" }
    var version: String?
    /// The version of the server binary this app carries, for the local
    /// machine; a running server with another version predates or postdates it.
    var bundledVersion: String? = nil
    var wireVersion: Int?
    var transport: Transport
    var connected: Bool
    var logURL: URL?
    /// These values are removed wherever they appear in the rendered report.
    var sensitiveHosts: [String] = []
    /// When the coordinator last checked these facts; nil means freshness is unknown.
    var checkedAt: Date? = nil
    var machine: String? = nil
    var pid: Int? = nil

    /// Whether the running server is the build this app carries, when both are known.
    var buildMatch: String {
        guard let version, let bundledVersion else { return "unknown (not supplied)" }
        return version == bundledVersion ? "yes" : "no (restart the server to update it)"
    }
}

/// An allowlisted support report. Paths/config are summarized; no files, environment,
/// processes, raw configuration, log contents or terminal contents are read.
struct Diagnostics {
    var appVersion: String
    var appBuild: String
    var wireVersion: Int
    var configURL: URL
    var stateURL: URL
    var logURL: URL
    var configIssueCount: Int
    var server: DiagnosticServer
    /// Coordinator-formatted numeric renderer facts and sanitized issue summaries.
    /// Never supply terminal text, raw logs or environment/configuration values.
    var renderingSummary: [String] = []
    /// Coordinator-formatted pane transport, response and prediction facts,
    /// from fixed labels and numbers only; never connection or error text.
    var interactionSummary: [String] = []
    var recentIssueSummary: [String] = []
    /// Milliseconds from launch to the first local pane's snapshot.
    var launchToFirstPaneMS: Int? = nil
    private var homeURL: URL

    /// Supply effective config/state/log paths and actual server information. A missing
    /// server version is reported as unknown rather than substituting the app version.
    init(server: DiagnosticServer, configURL: URL, stateURL: URL, logURL: URL,
         configIssueCount: Int = 0, wireVersion: Int = Wire.version, bundle: Bundle = .main,
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        self.wireVersion = wireVersion
        self.configURL = configURL
        self.stateURL = stateURL
        self.logURL = logURL
        self.configIssueCount = configIssueCount
        self.server = server
        self.homeURL = homeURL
    }

    /// Human-readable text safe to hand to copy/export callbacks. Invalid config entries
    /// are counted, never included: their original values may contain secrets.
    var text: String {
        let heading = """
        Koi diagnostics
        App version: \(appVersion)
        App build: \(appBuild)
        App wire version: \(wireVersion)
        """
        let details = """
        Machine: \(server.machine ?? "unknown (not supplied)")
        Server PID: \(server.pid.map(String.init) ?? "unknown (not supplied)")
        Server wire version: \(server.wireVersion.map(String.init) ?? "unknown (not supplied)")
        Server build matches this Koi: \(server.buildMatch)
        Server connected: \(server.connected ? "yes" : "no")
        Server checked at: \(server.checkedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown (not supplied)")
        Transport: \(server.transport.rawValue)
        Config path: \(displayPath(configURL))
        State path: \(displayPath(stateURL))
        App server log path: \(displayPath(logURL))
        Connected server log path: \(server.logURL.map(displayPath) ?? "unknown (not supplied)")
        Config issues: \(max(0, configIssueCount))
        First pane ready: \(launchToFirstPaneMS.map { "\($0) ms after launch" } ?? "unknown (not supplied)")
        Log contents and configuration values are excluded.

        """
        let version = server.version ?? "unknown (not supplied)"
        // Only the entire core build identity in this field may bypass token scrubbing.
        let trustedBuild = version.range(
            of: #"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\+[0-9a-f]{64}\z"#,
            options: .regularExpression) != nil && Self.redactHosts(version, hosts: server.sensitiveHosts) == version
        let extra = [("Panes", interactionSummary), ("Rendering", renderingSummary), ("Recent issues", recentIssueSummary)].compactMap { title, lines -> String? in
            guard !lines.isEmpty else { return nil }
            let bounded = lines.prefix(100).map { String($0.prefix(500)) }.joined(separator: "\n")
            return "\(title)\n" + Self.redact(bounded, sensitiveHosts: server.sensitiveHosts)
        }
        return ([Self.redact(heading, sensitiveHosts: server.sensitiveHosts),
                "Server version: \(trustedBuild ? version : Self.redact(version, sensitiveHosts: server.sensitiveHosts))",
                Self.redact(details, sensitiveHosts: server.sensitiveHosts)] + extra).joined(separator: "\n")
    }

    /// The coordinator supplies the pasteboard writer; this type never touches it directly.
    func copyFromUserAction(_ copy: (String) -> Void) { copy(text) }

    /// Pass only the URL returned by the app's save panel. An injected writer lets tests
    /// and UI handle export without a hidden destination or automatic home-directory writes.
    func exportFromUserAction(to destination: URL,
                              write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try write(Data(text.utf8), destination)
    }

    private func displayPath(_ url: URL) -> String {
        guard url.isFileURL else { return "[non-local path omitted]" }
        let path = url.standardizedFileURL.path
        let home = homeURL.standardizedFileURL.path
        return Paths.tilde(path, home: home)
    }

    /// Explicit host aliases plus common host/address and credential/token forms are
    /// removed even inside paths. Redaction intentionally favors privacy over exact paths.
    static func redact(_ input: String, sensitiveHosts: [String] = []) -> String {
        var result = redactHosts(input, hosts: sensitiveHosts)
        let patterns: [(String, String)] = [
            (#"(?i)\b(?:token|secret|password|passwd|api[-_]?key|authorization|bearer)\b\s*[:=]?\s*[^\s/]+"#, "[credential]"),
            (#"(?i)\b(?:sk-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+"#, "[token]"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "[token]"),
            (#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.:-]+\b"#, "[host]"),
            (#"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, "[host]"),
            (#"(?i)(?<![A-Za-z0-9])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:]{0,4}(?![A-Za-z0-9])"#, "[host]"),
            (#"(?i)\b(?:[a-z0-9-]+\.)+(?:local|internal|lan|com|net|org|io|dev|cloud|example)\b"#, "[host]"),
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    /// Match complete host/path tokens: short SSH aliases must not erase
    /// letters in labels, numbers in versions, or parts of unrelated hashes.
    private static func redactHosts(_ input: String, hosts: [String]) -> String {
        hosts.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(input) { result, host in
            let pattern = "(?i)(?<![A-Za-z0-9_.@%\\-])" + NSRegularExpression.escapedPattern(for: host) + "(?![A-Za-z0-9_.@%\\-])"
            return result.replacingOccurrences(of: pattern, with: "[host]", options: .regularExpression)
        }
    }
}

/// A bounded, in-memory history of caller-selected issue summaries, never raw logs,
/// terminal output or configuration. Recording performs no I/O or background work.
@MainActor @Observable final class DiagnosticIssues {
    /// Sanitized identity and occurrence times for one deduplicated issue summary.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let firstSeen: Date
        var lastSeen: Date
        var count: Int
        let subsystem: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let capacity: Int

    /// Retain at most capacity distinct summaries; nonpositive capacity disables storage.
    init(capacity: Int = 100) { self.capacity = max(0, capacity) }

    /// Redact and bound summaries before deduplication. Repeats keep their ID and move
    /// to the front; callers decide which failures are meaningful enough to record.
    func record(subsystem: String, message: String, at: Date = Date(), sensitiveHosts: [String] = []) {
        guard capacity > 0 else { return }
        let subsystem = Self.summary(subsystem, maxBytes: 50, sensitiveHosts: sensitiveHosts)
        let message = Self.summary(message, maxBytes: 500, sensitiveHosts: sensitiveHosts)
        if let index = entries.firstIndex(where: { $0.subsystem == subsystem && $0.message == message }) {
            var entry = entries.remove(at: index)
            entry.lastSeen = at
            if entry.count < Int.max { entry.count += 1 }
            entries.insert(entry, at: 0)
        } else {
            entries.insert(Entry(id: UUID(), firstSeen: at, lastSeen: at, count: 1,
                                 subsystem: subsystem, message: message), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        }
    }

    /// Discard all retained summaries without affecting the caller's issue sources.
    func clear() { entries.removeAll() }

    /// Scrub complete input before truncating so a cut-off credential cannot escape
    /// detection. Store a single line and preserve valid Unicode within the byte limit.
    private static func summary(_ input: String, maxBytes: Int, sensitiveHosts: [String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let redacted = Diagnostics.redact(input.replacingOccurrences(of: home, with: "~"),
                                          sensitiveHosts: sensitiveHosts)
        let line = redacted.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            guard bytes + size <= maxBytes else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}
