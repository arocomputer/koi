import Darwin
import Foundation
import Testing
@testable import Koi

extension SessionTests {
    /// Rapid changes from multiple workspaces share one in-memory layout and
    /// the final value survives an immediate app-termination flush.
    @Test @MainActor func layoutPersistenceMergesWorkspacesAndFlushesTheLatestSelection() throws {
        let server = try TestServer()
        defer { Layout.flush(); server.stop() }
        var first = Layout.load()
        first.machines["local"] = .init(tab: "a")
        first.save()
        var second = Layout.load()
        second.machines["remote"] = .init(tab: "r")
        second.machines["local"] = .init(tab: "b")
        second.save()
        Layout.flush()
        let saved = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: Paths.layout))
        #expect(saved.machines["local"]?.tab == "b")
        #expect(saved.machines["remote"]?.tab == "r")
    }
}

/// Layout security checks use only private files and never start a server.
@MainActor extension SessionTests {
    @Test func layoutRejectsUnsafeDirectoriesForReadsAndWrites() throws {
        try withPrivateLayoutDirectory { directory in
            let url = directory.appendingPathComponent("layout.json")
            var stored = Layout()
            stored.current = "disk-only"
            let original = try JSONEncoder().encode(stored)
            try original.write(to: url)
            #expect(chmod(directory.path, 0o755) == 0)
            #expect(Layout.load().current == nil)
            var changed = Layout()
            changed.current = "must-not-save"
            changed.save()
            Layout.flush()
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func queuedLayoutWritesRecheckPermissions() throws {
        try withPrivateLayoutDirectory { directory in
            var changed = Layout()
            changed.current = "queued"
            changed.save()
            #expect(chmod(directory.path, 0o755) == 0)
            Layout.flush()
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("layout.json").path))
        }
    }

    @Test func queuedLayoutWritesRejectReplacementSymlinks() throws {
        try withPrivateLayoutDirectory { directory in
            var changed = Layout()
            changed.current = "queued"
            changed.save()
            let moved = directory.appendingPathExtension("moved")
            try FileManager.default.moveItem(at: directory, to: moved)
            defer { try? FileManager.default.removeItem(at: moved) }
            #expect(symlink(moved.path, directory.path) == 0)
            Layout.flush()
            #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("layout.json").path))
        }
    }

    @Test func queuedLayoutWritesNeverRecreateRemovedDirectories() throws {
        try withPrivateLayoutDirectory { directory in
            var changed = Layout()
            changed.current = "queued"
            changed.save()
            try FileManager.default.removeItem(at: directory)
            Layout.flush()
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}

/// Restore KOI_DIR only after draining deferred writes; fixtures never use daily state.
@MainActor private func withPrivateLayoutDirectory(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("koi-layout-\(UUID())")
    try Paths.ensurePrivateDirectory(directory)
    let previous = ProcessInfo.processInfo.environment["KOI_DIR"]
    setenv("KOI_DIR", directory.path, 1)
    defer {
        Layout.flush()
        if let previous { setenv("KOI_DIR", previous, 1) } else { unsetenv("KOI_DIR") }
        try? FileManager.default.removeItem(at: directory)
    }
    try body(directory)
}
