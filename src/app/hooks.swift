import Foundation

/// Status hooks for the coding agents that can run a command on lifecycle
/// events: Claude Code and Codex. Each event runs `koi status STATE`, so a pane
/// shows working, blocked, done or idle without the agent having to remember to
/// report. The skills in integrations.swift only ask the agent to; hooks do it.
///
/// Both agents read the same shape: `hooks` maps an event to matcher groups, each
/// holding command handlers. Koi adds one group per event and recognizes its own
/// handlers by a marker comment at the end of the command, so installing is
/// idempotent and removing leaves every other hook, key and group as it was.
enum AgentHooks {
    /// Ends every command Koi installs; how removal and updates find them.
    static let marker = "# koi-status"

    enum Failure: LocalizedError {
        case unreadable, unexpectedShape
        var errorDescription: String? {
            switch self {
            case .unreadable: "The agent's settings file is not valid JSON. Koi will not change it."
            case .unexpectedShape: "The agent's settings file has hooks in a shape Koi does not recognize. Koi will not change it."
            }
        }
    }

    enum State: Equatable { case absent, installed, outdated }

    /// The events Koi reports on, and the status each means.
    static func events(for agent: AgentIntegration) -> [(event: String, status: String)] {
        let shared = [("UserPromptSubmit", "working"), ("PostToolUse", "working"),
                      ("PermissionRequest", "blocked"), ("Stop", "done"), ("SessionEnd", "idle")]
        switch agent {
        case .claude: return shared + [("StopFailure", "error")]
        case .codex: return shared + [("Interrupt", "idle")]
        }
    }

    /// Reports only from inside a Koi pane with `koi` reachable, and always
    /// exits 0 so a missing server never interrupts the agent.
    static func command(status: String) -> String {
        "command -v koi >/dev/null 2>&1 && [ -n \"$KOI_PANE\" ] && koi status \(status) >/dev/null 2>&1 || true \(marker)"
    }

    /// Adds Koi's hooks to `existing` (nil for a new file), replacing any older
    /// Koi hooks and touching nothing else.
    static func installing(into existing: Data?, for agent: AgentIntegration) throws -> Data {
        var root = try object(from: existing)
        var hooks = try hooksObject(in: root)
        for (event, status) in events(for: agent) {
            var groups = try groupList(hooks[event])
            groups = removingKoi(from: groups)
            groups.append(["hooks": [["type": "command", "command": command(status: status), "timeout": 5] as [String: Any]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Removes Koi's hooks from `existing`, dropping events and the `hooks` key
    /// only where Koi's were all they held.
    static func removing(from existing: Data) throws -> Data {
        var root = try object(from: existing)
        var hooks = try hooksObject(in: root)
        for event in Array(hooks.keys) {
            let groups = removingKoi(from: try groupList(hooks[event]))
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    static func state(of existing: Data?, for agent: AgentIntegration) throws -> State {
        guard let existing else { return .absent }
        let hooks = try hooksObject(in: try object(from: existing))
        var found = 0
        var current = 0
        for (event, status) in events(for: agent) {
            let handlers = try groupList(hooks[event]).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            let ours = handlers.compactMap { $0["command"] as? String }.filter { $0.hasSuffix(marker) }
            found += ours.isEmpty ? 0 : 1
            current += ours == [command(status: status)] ? 1 : 0
        }
        let total = events(for: agent).count
        if found == 0 { return .absent }
        return current == total ? .installed : .outdated
    }

    // MARK: JSON

    private static func object(from data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else {
            throw Failure.unreadable
        }
        return object
    }

    private static func hooksObject(in root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw Failure.unexpectedShape }
        return hooks
    }

    private static func groupList(_ value: Any?) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let groups = value as? [[String: Any]] else { throw Failure.unexpectedShape }
        return groups
    }

    /// Drops Koi's handlers from each group, and groups left with none.
    private static func removingKoi(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let kept = handlers.filter { ($0["command"] as? String)?.hasSuffix(marker) != true }
            if kept.count == handlers.count { return group }
            if kept.isEmpty { return nil }
            var copy = group
            copy["hooks"] = kept
            return copy
        }
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        return data
    }
}

extension AgentIntegrations {
    /// Claude Code keeps personal hooks in `settings.json` and a project's in
    /// `settings.local.json`, which Git ignores; Codex reads `hooks.json`.
    func hooksURL(for agent: AgentIntegration) -> URL {
        switch agent {
        case .claude: root.appendingPathComponent(root == home ? ".claude/settings.json" : ".claude/settings.local.json")
        case .codex: root.appendingPathComponent(".codex/hooks.json")
        }
    }

    func hooksState(for agent: AgentIntegration) throws -> AgentHooks.State {
        let url = hooksURL(for: agent)
        try validatePath(of: url)
        return try AgentHooks.state(of: InstallationFiles.contents(at: url), for: agent)
    }

    /// Adds Koi's hooks, keeping one `.koi-backup` of the file as it was.
    func installHooksFromUserAction(_ agent: AgentIntegration) throws {
        try rewriteHooks(for: agent) { try AgentHooks.installing(into: $0, for: agent) }
    }

    /// Removes only Koi's hooks.
    func uninstallHooksFromUserAction(_ agent: AgentIntegration) throws {
        guard try hooksState(for: agent) != .absent else { return }
        try rewriteHooks(for: agent) { try AgentHooks.removing(from: $0 ?? Data()) }
    }

    private func rewriteHooks(for agent: AgentIntegration, _ transform: (Data?) throws -> Data) throws {
        let url = hooksURL(for: agent)
        try validatePath(of: url)
        let fm = FileManager.default
        let existing = try InstallationFiles.contents(at: url)
        let updated = try transform(existing)
        if updated == existing { return }
        try InstallationFiles.validateParents(of: url, home: root, create: true)
        try validatePath(of: url)
        var permissions: Int = 0o600
        if existing != nil {
            permissions = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            let backup = url.appendingPathExtension("koi-backup")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
        }
        try updated.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
