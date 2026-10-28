import Foundation

/// What the app remembers between launches: the machines added, the one
/// shown, and per machine the tab it showed and the groups it had collapsed.
struct Layout: Codable, Sendable {
    struct Machine: Codable, Sendable {
        var tab: String?
        var collapsed: [String] = []

        init(tab: String? = nil, collapsed: [String] = []) {
            self.tab = tab
            self.collapsed = collapsed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tab = try c.decodeIfPresent(String.self, forKey: .tab)
            collapsed = try c.decodeIfPresent([String].self, forKey: .collapsed) ?? []
        }
    }

    var machines: [String: Machine] = [:]
    var deviceSymbols: [String: String] = [:]
    /// Hosts added, in the order they were.
    var hosts: [String] = []
    var current: String?

    init() {}

    /// Every key is optional, so a file from another build keeps what it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = try c.decodeIfPresent([String: Machine].self, forKey: .machines) ?? [:]
        deviceSymbols = try c.decodeIfPresent([String: String].self, forKey: .deviceSymbols) ?? [:]
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
        current = try c.decodeIfPresent(String.self, forKey: .current)
    }

    @MainActor private static var cached: (url: URL, value: Layout)?
    @MainActor private static var pending: [URL: Data] = [:]
    @MainActor private static var persistence: Task<Void, Never>?
    private static let writes = DispatchQueue(label: "koi.layout", qos: .utility)

    /// Load once per state directory. Selection reads this cache, never disk;
    /// path scoping also keeps private test servers out of the app's state.
    @MainActor
    static func load() -> Layout {
        let url = Paths.layout
        if let cached, cached.url == url { return cached.value }
        try? Paths.ensureDirs()
        let value = (try? JSONDecoder().decode(Layout.self, from: Data(contentsOf: url))) ?? Layout()
        cached = (url, value)
        return value
    }

    /// Publish immediately in memory, coalesce rapid selection changes, and
    /// serialize disk writes away from the main actor.
    @MainActor
    func save() {
        let url = Paths.layout
        Self.cached = (url, self)
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.pending[url] = data
        Self.persistence?.cancel()
        Self.persistence = Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let values = Self.pending
            Self.pending.removeAll()
            Self.persistence = nil
            Self.writes.async { Self.write(values) }
        }
    }

    /// App termination and isolated tests drain the newest values after any
    /// older writes, so quitting never loses the final selected tab.
    @MainActor static func flush() {
        persistence?.cancel()
        persistence = nil
        let values = pending
        pending.removeAll()
        writes.sync { write(values) }
    }

    private static func write(_ values: [URL: Data]) {
        for (url, data) in values {
            // A removed state directory (including an ended private test)
            // must not be recreated by a previously queued save.
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { continue }
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension Endpoint {
    /// The endpoint as `Layout` keys it.
    var key: String {
        switch self {
        case .local: "local"
        case .ssh(let host): host
        }
    }
}
