import Foundation
import SwiftUI
import AppKit
import Observation

/// Numeric release versions with SemVer prerelease precedence; v-prefixes and 1–3
/// numeric components are accepted. Build metadata does not affect precedence.
struct ReleaseVersion: Comparable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") { value.removeFirst() }
        let build = value.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2 else { return nil }
        func identifiers(_ text: Substring) -> [String]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } }) else { return nil }
            return parts
        }
        if build.count == 2, identifiers(build[1]) == nil { return nil }
        let halves = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(core.count) else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
        if halves.count == 2 {
            guard let parts = identifiers(halves[1]), parts.allSatisfy({
                !$0.utf8.allSatisfy({ (48...57).contains($0) }) || $0.count == 1 || $0.first != "0"
            }) else { return nil }
            prerelease = parts
        } else {
            prerelease = []
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right { return left < right }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = left.utf8.allSatisfy { (48...57).contains($0) }
            let rn = right.utf8.allSatisfy { (48...57).contains($0) }
            if ln != rn { return ln }
            if ln, left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// A validated, published release page, never an executable or download instruction.
struct UpdateRelease: Equatable {
    var version: String
    var pageURL: URL
}

/// Manual release checks. Initialization and source changes perform no network I/O.
/// UI may persist sourceURL separately in UserDefaults; there is deliberately no default feed.
@MainActor @Observable final class UpdateChecker {
    enum State: Equatable {
        case notConfigured, idle, checking, upToDate
        case available(UpdateRelease)
        case failed(String)
    }
    enum Failure: LocalizedError {
        case invalidURL, invalidCurrentVersion, invalidFeed, http(Int), noStableRelease
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Use an HTTPS release or feed URL without credentials."
            case .invalidCurrentVersion: "The installed app version cannot be compared with release versions."
            case .invalidFeed: "The release feed is invalid or has no valid HTTPS release pages."
            case .http(let code): "The release server returned HTTP \(code)."
            case .noStableRelease: "The feed contains no published stable releases."
            }
        }
    }

    var sourceURL: URL? {
        didSet {
            generation = UUID()
            state = sourceURL == nil ? .notConfigured : .idle
            lastChecked = nil
        }
    }
    let currentVersion: String
    private(set) var state: State
    private(set) var lastChecked: Date?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    /// Inject fetch in tests. The default URLSession is contacted only by checkFromUserAction.
    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
         sourceURL: URL? = nil,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         }) {
        self.currentVersion = currentVersion
        self.sourceURL = sourceURL
        self.fetch = fetch
        state = sourceURL == nil ? .notConfigured : .idle
    }

    /// Bind to Check for Updates. Source edits invalidate any response already in flight.
    func checkFromUserAction() async {
        guard let sourceURL else { state = .notConfigured; return }
        guard state != .checking else { return }
        let token = UUID()
        generation = token
        state = .checking
        do {
            guard let current = ReleaseVersion(currentVersion) else { throw Failure.invalidCurrentVersion }
            var request = URLRequest(url: try Self.requestURL(for: sourceURL))
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json, application/json, application/atom+xml", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            guard generation == token else { return }
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidFeed }
            guard let finalURL = http.url, Self.safeURL(finalURL) else { throw Failure.invalidURL }
            guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
            guard data.count <= 2 * 1024 * 1024 else { throw Failure.invalidFeed }
            let release = try Self.latestRelease(in: data)
            guard let latest = ReleaseVersion(release.version) else { throw Failure.invalidFeed }
            state = latest > current ? .available(release) : .upToDate
            lastChecked = Date()
        } catch {
            guard generation == token else { return }
            state = .failed(error is Failure ? error.localizedDescription : "Could not read the release feed. Check the URL and connection.")
        }
    }

    /// Bind to Open Release; the coordinator supplies NSWorkspace.open or a test recorder.
    func openReleaseFromUserAction(_ open: (URL) -> Void) {
        guard case .available(let release) = state else { return }
        open(release.pageURL)
    }

    /// GitHub /OWNER/REPO/releases[/latest] is converted to its public API. Other HTTPS
    /// URLs are fetched verbatim, including GitHub releases.atom and private JSON feeds.
    static func requestURL(for source: URL) throws -> URL {
        guard safeURL(source) else { throw Failure.invalidURL }
        let parts = source.pathComponents.filter { $0 != "/" }
        if source.host?.lowercased() == "github.com", parts.count >= 3,
           parts[2] == "releases", parts.count == 3 || (parts.count == 4 && parts[3] == "latest") {
            var result = URLComponents()
            result.scheme = "https"
            result.host = "api.github.com"
            result.path = "/repos/\(parts[0])/\(parts[1])/releases"
            result.queryItems = [URLQueryItem(name: "per_page", value: "100")]
            guard let url = result.url else { throw Failure.invalidURL }
            return url
        }
        return source
    }

    /// Accept GitHub release objects/arrays, JSON {version,url} objects/arrays, or Atom
    /// entries with a GitHub /releases/tag/VERSION link. Ignore drafts and prereleases.
    static func latestRelease(in data: Data) throws -> UpdateRelease {
        let candidates: [UpdateRelease]
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 60 {
            let feed = ReleaseAtomReader()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = feed
            guard parser.parse() else { throw Failure.invalidFeed }
            candidates = feed.releases
        } else {
            struct Entry: Decodable {
                var tag_name: String?
                var html_url: URL?
                var version: String?
                var url: URL?
                var draft: Bool?
                var prerelease: Bool?
            }
            let decoder = JSONDecoder()
            let entries: [Entry]
            do {
                if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
                    entries = try decoder.decode([Entry].self, from: data)
                } else {
                    entries = [try decoder.decode(Entry.self, from: data)]
                }
            } catch { throw Failure.invalidFeed }
            candidates = entries.compactMap {
                guard $0.draft != true, $0.prerelease != true,
                      let version = $0.tag_name ?? $0.version, let url = $0.html_url ?? $0.url else { return nil }
                return UpdateRelease(version: version, pageURL: url)
            }
        }
        let valid = candidates.compactMap { release -> (UpdateRelease, ReleaseVersion)? in
            guard safeURL(release.pageURL), let version = ReleaseVersion(release.version), version.prerelease.isEmpty else { return nil }
            return (release, version)
        }
        guard let latest = valid.max(by: { $0.1 < $1.1 }) else { throw Failure.noStableRelease }
        return latest.0
    }

    private static func safeURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
}

/// Only Atom entry links are read; feed text, HTML and external entities are never executed.
private final class ReleaseAtomReader: NSObject, XMLParserDelegate {
    var releases: [UpdateRelease] = []
    private var inEntry = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "entry" { inEntry = true }
        guard inEntry, elementName == "link", attributeDict["rel"] == nil || attributeDict["rel"] == "alternate",
              let href = attributeDict["href"], let url = URL(string: href) else { return }
        let parts = url.pathComponents
        guard parts.count >= 4, parts[parts.count - 3] == "releases", parts[parts.count - 2] == "tag" else { return }
        releases.append(UpdateRelease(version: url.lastPathComponent, pageURL: url))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "entry" { inEntry = false }
    }
}

/// Manual release checks with a user-supplied feed; an unpublished app has no
/// implicit network endpoint and never claims to be current without checking.
struct UpdateSettingsView: View {
    let checker: UpdateChecker
    @State private var source = UserDefaults.standard.string(forKey: "releaseFeedURL") ?? ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates").font(.headline)
            Text("Koi is not published yet. Configure a GitHub releases page or HTTPS release feed when one is available.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://github.com/owner/repository/releases", text: $source)
                .textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Button("Save Source", action: save)
                Button("Check Now") { save(); if error == nil { Task { await checker.checkFromUserAction() } } }
                    .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checker.state == .checking)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            switch checker.state {
            case .notConfigured: Text("No update source configured.").foregroundStyle(.secondary)
            case .idle: Text("Ready to check.").foregroundStyle(.secondary)
            case .checking: ProgressView("Checking releases…")
            case .upToDate: Text("This version is up to date.")
            case .available(let release):
                Button("Open Release \(release.version)") { checker.openReleaseFromUserAction { NSWorkspace.shared.open($0) } }
            case .failed(let message): Text(message).foregroundStyle(.red)
            }
        }
        .font(.callout)
        .onAppear {
            if checker.sourceURL == nil, let url = URL(string: source), (try? UpdateChecker.requestURL(for: url)) != nil {
                checker.sourceURL = url
            }
        }
    }

    private func save() {
        do {
            let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { checker.sourceURL = nil; UserDefaults.standard.removeObject(forKey: "releaseFeedURL") }
            else {
                guard let url = URL(string: value) else { throw UpdateChecker.Failure.invalidURL }
                _ = try UpdateChecker.requestURL(for: url)
                checker.sourceURL = url
                UserDefaults.standard.set(value, forKey: "releaseFeedURL")
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
