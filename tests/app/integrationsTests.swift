import Foundation
import Testing
@testable import Koi

/// Integration mutations are confined to fresh temporary directories, never the user's home.
@Suite struct IntegrationsTests {
    @Test(arguments: AgentIntegration.allCases) func installAndUninstallOnlyOwnTheDedicatedFile(agent: AgentIntegration) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let integrations = AgentIntegrations(root: root)
        let unrelated = root.appendingPathComponent("settings.json")
        try Data("existing settings".utf8).write(to: unrelated)
        #expect(try integrations.installation(for: agent) == .absent)
        try integrations.installFromUserAction(agent)
        try integrations.installFromUserAction(agent)
        #expect(try integrations.installation(for: agent) == .installed)
        let neighbor = integrations.fileURL(for: agent).deletingLastPathComponent().appendingPathComponent("notes.md")
        try Data("keep me".utf8).write(to: neighbor)
        try integrations.uninstallFromUserAction(agent)
        #expect(try integrations.installation(for: agent) == .absent)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "existing settings")
        #expect(try String(contentsOf: neighbor, encoding: .utf8) == "keep me")
    }

    @Test func existingOrEditedGuidanceIsPreserved() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let integrations = AgentIntegrations(root: root)
        try integrations.installFromUserAction(.codex)
        let edited = AgentIntegrations.guidance + Data("Personal instructions".utf8)
        try edited.write(to: integrations.fileURL(for: .codex))
        #expect(try integrations.installation(for: .codex) == .conflict)
        #expect(throws: (any Error).self) { try integrations.installFromUserAction(.codex) }
        #expect(throws: (any Error).self) { try integrations.uninstallFromUserAction(.codex) }
        #expect(try Data(contentsOf: integrations.fileURL(for: .codex)) == edited)
    }

    @Test(arguments: [false, true]) func symlinkedAndDanglingSkillParentsAreRejected(dangling: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        if !dangling { try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".agents"), withDestinationURL: outside)
        let integrations = AgentIntegrations(root: root)
        #expect(throws: (any Error).self) { try integrations.installFromUserAction(.codex) }
        #expect(throws: (any Error).self) { try integrations.uninstallFromUserAction(.codex) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("skills").path))
    }

    // MARK: Status hooks

    private func json(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func handlers(_ root: NSDictionary, event: String) -> [[String: Any]] {
        let groups = ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    @Test(arguments: AgentIntegration.allCases) func hooksRoundTrip(agent: AgentIntegration) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let integrations = AgentIntegrations(root: root)
        let url = integrations.hooksURL(for: agent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        {"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"audit.sh"}]}]}}
        """
        try Data(original.utf8).write(to: url)

        #expect(try integrations.hooksState(for: agent) == .absent)
        try integrations.installHooksFromUserAction(agent)
        let installed = try Data(contentsOf: url)
        try integrations.installHooksFromUserAction(agent)
        #expect(try Data(contentsOf: url) == installed, "installing twice must change nothing")
        #expect(try integrations.hooksState(for: agent) == .configured)

        let after = try json(installed)
        #expect(after["model"] as? String == "x")
        #expect(handlers(after, event: "PreToolUse").count == 1)
        let stop = handlers(after, event: "Stop").compactMap { $0["command"] as? String }
        #expect(stop.contains("say done"), "the user's own Stop hook stays")
        #expect(stop.filter { $0.hasSuffix(AgentHooks.marker) }.count == 1)
        for event in AgentHooks.events(for: agent) {
            let ours = handlers(after, event: event).compactMap { $0["command"] as? String }.filter { $0.hasSuffix(AgentHooks.marker) }
            #expect(ours == [AgentHooks.command(for: agent, event: event)], "\(event)")
        }

        try integrations.uninstallHooksFromUserAction(agent)
        #expect(try json(Data(contentsOf: url)) == json(Data(original.utf8)))
        #expect(try integrations.hooksState(for: agent) == .absent)
        #expect(try Data(contentsOf: url.appendingPathExtension("koi-backup")) == Data(original.utf8))
    }

    @Test func hookReportsOnlyInAPane() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("calls")
        let fake = bin.appendingPathComponent("koi")
        try Data("#!/bin/sh\necho \"$*\" >> '\(log.path)'\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func run(_ event: String, environment: [String: String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", AgentHooks.command(for: .claude, event: event)]
            p.environment = environment
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        let path = bin.path + ":/usr/bin:/bin"
        #expect(try run("UserPromptSubmit", environment: ["PATH": path, "KOI_PANE": "abc"]) == 0)
        #expect(try String(contentsOf: log, encoding: .utf8) == "agent hook claude UserPromptSubmit\n")
        try FileManager.default.removeItem(at: log)
        #expect(try run("Stop", environment: ["PATH": path]) == 0, "outside a pane it is a successful no-op")
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(try run("Stop", environment: ["PATH": "/usr/bin:/bin", "KOI_PANE": "abc"]) == 0, "no koi on PATH must not fail the agent")
    }

    @Test func hooksRefuseOddSettings() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let integrations = AgentIntegrations(root: root)
        let url = integrations.hooksURL(for: .claude)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["{ not json", "[1,2]", #"{"hooks":[]}"#, #"{"hooks":{"Stop":{"a":1}}}"#, #"{"hooks":{"Stop":[{"hooks":"bad"}]}}"#] {
            try Data(text.utf8).write(to: url)
            #expect(throws: AgentHooks.Failure.self) { try integrations.installHooksFromUserAction(.claude) }
            #expect(try String(contentsOf: url, encoding: .utf8) == text, "unchanged: \(text)")
        }
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("koi-backup").path))
    }

    @Test func staleHooksUpdateInPlace() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let integrations = AgentIntegrations(root: root)
        let url = integrations.hooksURL(for: .codex)
        try integrations.installHooksFromUserAction(.codex)
        let stale = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "koi agent hook codex UserPromptSubmit", with: "koi agent hook codex Unsupported")
        try Data(stale.utf8).write(to: url)
        #expect(try integrations.hooksState(for: .codex) == .outdated)
        try integrations.installHooksFromUserAction(.codex)
        #expect(try integrations.hooksState(for: .codex) == .configured)
        for event in AgentHooks.events(for: .codex) {
            let ours = try handlers(json(Data(contentsOf: url)), event: event).filter {
                ($0["command"] as? String)?.hasSuffix(AgentHooks.marker) == true
            }
            #expect(ours.count == 1, "\(event)")
        }
    }

    @Test func configurationHealthRejectsHandlersThatWillNotRunTheAdapter() throws {
        let data = try AgentHooks.installing(into: nil, for: .codex)
        for field in ["matcher", "type", "timeout", "async"] {
            var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
            var groups = try #require(hooks["Stop"])
            if field == "matcher" { groups[0]["matcher"] = "OnlyOneTool" }
            else {
                var handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
                switch field {
                case "type": handlers[0][field] = "prompt"
                case "timeout": handlers[0][field] = 999
                default: handlers[0][field] = true
                }
                groups[0]["hooks"] = handlers
            }
            hooks["Stop"] = groups; root["hooks"] = hooks
            let edited = try JSONSerialization.data(withJSONObject: root)
            #expect(try AgentHooks.state(of: edited, for: .codex) == .outdated)
        }
    }

    @Test func obsoleteHookEventsAreUpdatedAndRemoved() throws {
        let old = Data(#"{"hooks":{"OldEvent":[{"hooks":[{"type":"command","command":"koi status done # koi-status"},{"type":"command","command":"foreign"}]}]}}"#.utf8)
        #expect(try AgentHooks.state(of: old, for: .codex) == .outdated)
        let updated = try AgentHooks.installing(into: old, for: .codex)
        #expect(try AgentHooks.state(of: updated, for: .codex) == .configured)
        #expect(handlers(try json(updated), event: "OldEvent").compactMap { $0["command"] as? String } == ["foreign"])
        let removed = try AgentHooks.removing(from: old)
        #expect(handlers(try json(removed), event: "OldEvent").compactMap { $0["command"] as? String } == ["foreign"])
    }

    @Test func hooksKeepModeAndScope() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        for dir in [home, project] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let personal = AgentIntegrations(root: home, home: home)
        let scoped = AgentIntegrations(root: project, home: home)
        #expect(personal.hooksURL(for: .claude).lastPathComponent == "settings.json")
        #expect(scoped.hooksURL(for: .claude).lastPathComponent == "settings.local.json")

        let url = personal.hooksURL(for: .claude)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try personal.installHooksFromUserAction(.claude)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try scoped.installHooksFromUserAction(.codex)
        let created = scoped.hooksURL(for: .codex)
        #expect((try FileManager.default.attributesOfItem(atPath: created.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func hooksRefuseSymlinks() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".codex"), withDestinationURL: outside)
        let integrations = AgentIntegrations(root: project)
        #expect(throws: (any Error).self) { try integrations.installHooksFromUserAction(.codex) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("koi-integrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
