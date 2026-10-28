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

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("koi-integrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
