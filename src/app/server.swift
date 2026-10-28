import Foundation
import Observation

/// Facts supplied by the running server, kept separate from the bundled binary.
/// Capability probes are read-only and safe against older protocol-v6 servers.
@MainActor @Observable final class ServerInspector {
    private(set) var replies: [Endpoint: Wire.Result] = [:]
    private(set) var errors: [Endpoint: String] = [:]
    private(set) var attempted: Set<Endpoint> = []
    private(set) var checkedAt: [Endpoint: Date] = [:]
    @ObservationIgnored private var generations: [Endpoint: UUID] = [:]

    func invalidate(_ endpoint: Endpoint) {
        generations[endpoint] = UUID()
        attempted.remove(endpoint)
        replies[endpoint] = nil
        errors[endpoint] = nil
        checkedAt[endpoint] = nil
    }

    func refresh(_ endpoint: Endpoint, command: @escaping @MainActor (Wire.Command) async throws -> Wire.Result) async {
        let generation = UUID()
        attempted.insert(endpoint)
        generations[endpoint] = generation
        do {
            let result = try await command(.init(op: .serverInfo))
            guard generations[endpoint] == generation else { return }
            if result.error == nil {
                replies[endpoint] = result
                checkedAt[endpoint] = Date()
            }
            errors[endpoint] = result.error
        } catch {
            guard generations[endpoint] == generation else { return }
            errors[endpoint] = error.localizedDescription
        }
    }

    func supports(_ capability: String, at endpoint: Endpoint) -> Bool {
        replies[endpoint]?.supports(capability) == true
    }

    func summary(for endpoint: Endpoint) -> String {
        guard let reply = replies[endpoint], reply.error == nil else {
            return errors[endpoint].map { "Server details unavailable: \($0)" } ?? "Reading server details…"
        }
        let version = reply.serverVersion ?? "Unknown version"
        let uptime = reply.uptimeSeconds.map { " · running \($0 / 60)m" } ?? ""
        let stale = endpoint == .local && LocalServer.bundledVersion.map { $0 != reply.serverVersion } == true
        return version + uptime + (stale ? " · older than this Koi; restart it to update" : "")
    }

    /// A color query and the visible terminal should use the same defaults.
    static var appearance: Wire.Appearance {
        func hex(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
            String(format: "%02x%02x%02x", r, g, b)
        }
        let theme = Theme.current
        return .init(foreground: hex(theme.foreground.r, theme.foreground.g, theme.foreground.b),
                     background: hex(theme.background.r, theme.background.g, theme.background.b),
                     cursor: hex(theme.cursor.r, theme.cursor.g, theme.cursor.b),
                     scrollbackMB: Config.current.scrollbackMB)
    }
}
