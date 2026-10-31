import Foundation
import AppKit
import SwiftUI

/// Supported local agent skill directories, relative to an explicitly chosen home or project.
enum AgentIntegration: String, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude Code" }
    var relativePath: String {
        (self == .codex ? ".agents" : ".claude") + "/skills/koi-terminal/SKILL.md"
    }

    /// Guidance is advisory: neither skills nor output heuristics guarantee lifecycle status.
    var supportDescription: String {
        "Installs a local koi-terminal skill. Invoke " + (self == .codex ? "$koi-terminal" : "/koi-terminal")
        + " in a Koi pane. This teaches stock CLI use and koi status reports using KOI_PANE; "
        + "it does not install hooks or guarantee blocked/done/error reports. "
        + "Status comes from explicit CLI reports, server output inference or legacy OSC 7501 reports."
    }
}

/// Opt-in, single-file skill installation. Call mutations only from user-click handlers.
/// No implicit home directory, config edits, commands, hooks or background installation.
struct AgentIntegrations {
    enum Installation: Equatable { case absent, installed, conflict }
    enum Failure: LocalizedError {
        case unsafePath, foreignFile
        var errorDescription: String? {
            switch self {
            case .unsafePath: "The integration path must be a local directory without symbolic links."
            case .foreignFile: "The guidance file already exists or was edited. Koi will preserve it."
            }
        }
    }

    let root: URL
    /// The user's home; a root equal to it holds personal settings, any other a project's.
    let home: URL

    /// Use a home URL for personal skills or a repository URL for project skills.
    init(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.root = root.standardizedFileURL
        self.home = home.standardizedFileURL
    }

    func fileURL(for agent: AgentIntegration) -> URL {
        root.appendingPathComponent(agent.relativePath)
    }

    /// Read-only ownership check; byte-for-byte equality is required before removing a file.
    func installation(for agent: AgentIntegration) throws -> Installation {
        try validatePath(of: fileURL(for: agent))
        let url = fileURL(for: agent)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { return .conflict }
        return try Data(contentsOf: url) == Self.guidance ? .installed : .conflict
    }

    /// Creates only the dedicated skill; an existing file is never overwritten.
    func installFromUserAction(_ agent: AgentIntegration) throws {
        switch try installation(for: agent) {
        case .installed: return
        case .conflict: throw Failure.foreignFile
        case .absent: break
        }
        try FileManager.default.createDirectory(at: fileURL(for: agent).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try validatePath(of: fileURL(for: agent))
        try Self.guidance.write(to: fileURL(for: agent), options: .withoutOverwriting)
    }

    /// Removes only unchanged Koi guidance. Leaves directories and all other files intact.
    func uninstallFromUserAction(_ agent: AgentIntegration) throws {
        switch try installation(for: agent) {
        case .absent: return
        case .conflict: throw Failure.foreignFile
        case .installed: try FileManager.default.removeItem(at: fileURL(for: agent))
        }
    }

    /// Reject symlinks from the explicitly chosen root through the leaf, including
    /// dangling links. System ancestors such as macOS /var are outside that boundary.
    func validatePath(of file: URL) throws {
        guard root.isFileURL else { throw Failure.unsafePath }
        try InstallationFiles.validateParents(of: file, home: root)
        let fm = FileManager.default
        var cursor = file
        while true {
            do {
                let attributes = try fm.attributesOfItem(atPath: cursor.path)
                let type = attributes[.type] as? FileAttributeType
                guard type != .typeSymbolicLink,
                      cursor == file || type == .typeDirectory else { throw Failure.unsafePath }
            } catch CocoaError.fileReadNoSuchFile { }
            if cursor.path == root.path { break }
            guard cursor.path != "/" else { throw Failure.unsafePath }
            cursor.deleteLastPathComponent()
        }
    }

    /// Uses stock CLI reportStatus and the older OSC 7501 contract in core/pane.zig.
    /// Skill locations: developers.openai.com/codex/skills and code.claude.com/docs/en/skills.
    static let guidance = Data("""
    ---
    name: koi-terminal
    description: Report task status and use Koi's stock CLI when working in a Koi terminal pane.
    ---
    <!-- Owned by Koi integration v1. Edited files are preserved on uninstall. -->

    Work inside an existing Koi pane. Run `koi help` to check the installed CLI's commands.
    `koi ls --json` lists tabs and pane metadata, including status. Use stable full IDs.
    `koi capture TARGET` reads terminal contents; use it only when the task calls for that data.
    `koi send TARGET TEXT` sends input and can execute commands: use only for the user's task.
    `koi new --cwd DIR` creates a tab; `koi split TARGET` creates a pane.
    `koi close TARGET` ends a pane and its running process; obtain user intent before closing work.
    Newer stock CLI versions provide `koi info [--json]` for actual running server information,
    `koi clear [TARGET]` to erase scrollback, and `koi reset [TARGET]` to reset the terminal
    engine without replacing its process. Check `koi help` for availability before use.
    Clear and reset affect the user's terminal state; use only when requested.
    Prefer `koi status [PANE] STATE` on CLI/server versions supporting `reportStatus`.
    Inside a Koi pane, `koi status working` uses KOI_PANE; an explicit equivalent is
    `koi status "$KOI_PANE" working`. The states are working, blocked, done, error and idle.
    Report working at task start, blocked when waiting for user input, done on completion,
    and error on failure. Use idle when no task is active. The CLI sends status directly
    to the server, so captured tool stdout does not prevent reports. Preserve KOI_DIR and
    the pane's server context, especially in Koid; do not target unrelated panes.
    Check `koi help` and `koi info --json` for command/capability support. Older servers
    without reportStatus may use OSC 7501 only when the shell has a controlling Koi terminal:
    `printf '\\033]7501;state=working\\007' > /dev/tty`
    Substitute blocked, done, error or idle as needed. `state=clear` restores server inference.
    Do not send these reports outside a Koi pane. Captured tool stdout may never reach the
    pane; without a controlling Koi terminal these reports cannot communicate status.
    This skill installs no hooks. The CLI supports explicit reporting, but loading guidance
    does not guarantee automatic agent lifecycle reports. Never invent hooks or commands.
    Do not read environment dumps, credentials, or unrelated terminal contents.

    """.utf8)
}

/// Integration buttons are the only mutation entry points. Each card names the
/// destination and keeps edited files intact on uninstall.
struct IntegrationSettingsView: View {
    @State private var root = FileManager.default.homeDirectoryForCurrentUser
    @State private var error: String?
    @State private var revision = 0
    private var integrations: AgentIntegrations { .init(root: root) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shell Integration").font(.headline)
            Text("Zsh and fish shells started by Koi carry its prompt integration: Previous/Next Prompt and exact program names in pane headers, with nothing written to your files. For bash, source \"$KOI_SHELL_INTEGRATION/bash/koi.bash\" from ~/.bashrc.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Agent Guidance").font(.headline)
            Text("Skills teach an agent Koi's commands and status reporting. They install no hooks; hooks are below.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(root.path).font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Choose Project…") {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = true; picker.canChooseFiles = false
                    picker.begin { result in if result == .OK, let url = picker.url { root = url; revision += 1 } }
                }
                Button("Home") { root = FileManager.default.homeDirectoryForCurrentUser; revision += 1 }
            }
            ForEach(AgentIntegration.allCases) { agent in
                HStack {
                    VStack(alignment: .leading) {
                        Text(agent.title)
                        Text(agent.relativePath).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let installed = (try? integrations.installation(for: agent)) == .installed
                    Button(installed ? "Remove" : "Install") {
                        perform { if installed { try integrations.uninstallFromUserAction(agent) } else { try integrations.installFromUserAction(agent) } }
                    }
                }
            }
            Divider()
            Text("Agent Status Hooks").font(.headline)
            Text("Hooks make Claude Code and Codex report working, blocked, done and idle to the pane they run in, with no cooperation from the agent. Each adds a few entries to the agent's own settings file, keeps a .koi-backup of it, and Remove takes out only Koi's entries.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(AgentIntegration.allCases) { agent in
                HStack {
                    VStack(alignment: .leading) {
                        Text(agent.title)
                        Text(integrations.hooksURL(for: agent).path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    let state = (try? integrations.hooksState(for: agent)) ?? .absent
                    Button(state == .installed ? "Remove" : state == .outdated ? "Update" : "Install") {
                        perform {
                            if state == .installed { try integrations.uninstallHooksFromUserAction(agent) }
                            else { try integrations.installHooksFromUserAction(agent) }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .id(revision)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); revision += 1; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
