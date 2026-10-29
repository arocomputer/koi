import AppKit
import Testing
@testable import Koi

extension SessionTests {
    /// Selecting a report scope never selects/creates a workspace or starts SSH.
    @Test @MainActor func diagnosticsReportsFollowTheInspectedMachineWithoutConnecting() async throws {
        try await withDiagnosticDirectory {
            let owner = AppDelegate()
            let remote = Endpoint.ssh("fixture")
            await owner.serverInspector.refresh(.local) { _ in .init(serverVersion: "1.0.0", serverPID: 123, protocolVersion: 6) }
            await owner.serverInspector.refresh(remote) { _ in .init(serverVersion: "2.0.0", serverPID: 456, protocolVersion: 6) }
            #expect(owner.diagnosticReport(for: .local).server.version == "1.0.0")
            #expect(owner.diagnosticSnapshot(for: remote).report.server.version == "2.0.0")
            #expect(owner.diagnosticSnapshot(for: remote).report.server.pid == 456)
            #expect(!owner.diagnosticReport(for: remote).text.contains("fixture"), "removed or unregistered aliases must also be redacted")
            #expect(owner.machines.current == .local)
            #expect(owner.machines.allWorkspaces.isEmpty)
        }
    }

    /// A late probe cannot replace a newly selected scope; copy/export use the visible report.
    @Test @MainActor func diagnosticsSelectionInvalidatesLateRefreshAndKeepsCopyScope() async throws {
        _ = NSApplication.shared
        var continuation: CheckedContinuation<Void, Never>?
        var copied = "", exported = ""
        let remote = Endpoint.ssh("fixture")
        let controller = DiagnosticsWindowController(machine: .local, sample: diagnosticFixture,
            probe: { _ in await withCheckedContinuation { continuation = $0 } },
            copy: { copied = $0.server.version ?? "" }, export: { exported = $0.server.version ?? "" },
            openLogs: {}, resetRendering: { _ in }, clearIssues: {})
        defer { continuation?.resume(); controller.close() }
        controller.refresh()
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(continuation != nil)
        controller.select(remote)
        continuation?.resume(); continuation = nil
        try await Task.sleep(for: .milliseconds(20))
        controller.copyReport(); controller.exportReport()
        #expect(controller.screen.snapshot.machine == remote)
        #expect(!controller.screen.refreshing)
        #expect(copied == "2.0.0" && exported == "2.0.0")
        #expect(controller.window?.isVisible == false)
    }

    /// A failed refresh keeps its last successful facts visibly dated until reconnect invalidates them.
    @Test @MainActor func diagnosticProbeFailurePreservesDatedFacts() async throws {
        let inspector = ServerInspector()
        await inspector.refresh(.local) { _ in .init(serverVersion: "1.0.0", protocolVersion: 6) }
        let checked = try #require(inspector.checkedAt[.local])
        await inspector.refresh(.local) { _ in throw WorkspaceCommandError("fixture offline") }
        #expect(inspector.replies[.local]?.serverVersion == "1.0.0")
        #expect(inspector.checkedAt[.local] == checked)
        #expect(inspector.errors[.local] == "fixture offline")
        inspector.invalidate(.local)
        #expect(inspector.checkedAt[.local] == nil && inspector.replies[.local] == nil)
    }

    /// Optional opaque previews render all four real sections at both window widths.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOI_VISUALS"] != nil))
    @MainActor func diagnosticsWindowPreviews() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KOI_VISUALS"]))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let controller = DiagnosticsWindowController(machine: .local, sample: diagnosticFixture,
            probe: { _ in }, copy: { _ in }, export: { _ in }, openLogs: {}, resetRendering: { _ in }, clearIssues: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        for width in [820, 660] {
            window.setContentSize(NSSize(width: width, height: 620))
            for tab in DiagnosticsScreen.Tab.allCases {
                controller.screen.tab = tab
                let view = try #require(window.contentView)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
                let rect = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                NSColor(Theme.current.backgroundColor).setFill(); rect.fill()
                bitmap.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                let data = try #require(image.representation(using: .png, properties: [:]))
                try data.write(to: root.appendingPathComponent("diagnostics-\(tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-\(width).png"))
            }
        }
    }
}

/// Fixture data contains no user paths, terminal output, actual network hosts or GPU queries.
@MainActor private func diagnosticFixture(_ endpoint: Endpoint) -> DiagnosticsSnapshot {
    var report = Diagnostics(server: .init(version: endpoint == .local ? "1.0.0" : "2.0.0", wireVersion: 6, transport: .localSocket,
        connected: true, checkedAt: Date(timeIntervalSince1970: 1_793_000_000)),
        configURL: URL(fileURLWithPath: "/fixture/config"), stateURL: URL(fileURLWithPath: "/fixture/state"), logURL: URL(fileURLWithPath: "/fixture/log"))
    report.appVersion = "0.1.0"; report.appBuild = "fixture"
    let stats = RenderDiagnosticsSnapshot(device: "Fixture GPU", drawableWidth: 1200, drawableHeight: 800,
        framesSubmitted: 40, framesCompleted: 39, framesFailed: 0, pendingFrame: true, inFlight: 1,
        deferred: ["inflight": 2], lastCPUFrameMS: 0.4, maxCPUFrameMS: 1.2, lastGPUFrameMS: 0.15,
        atlasBytes: 16 * 1024 * 1024, bufferBytes: 1024 * 1024, issues: [])
    return .init(machine: endpoint, title: endpoint == .local ? "This Mac" : "Fixture Remote",
        machines: [.init(endpoint: .local, title: "This Mac"), .init(endpoint: .ssh("fixture"), title: "Fixture Remote")],
        report: report, server: .init(serverVersion: report.server.version, serverPID: 123, protocolVersion: 6, uptimeSeconds: 65, capabilities: ["serverInfo", "configurePane"]),
        checkedAt: report.server.checkedAt, refreshError: nil, configurationIssues: [],
        panes: [.init(id: "fixture", title: "Pane fixture", connection: "Connected", rendering: stats)],
        issues: [.init(id: "fixture", date: Date(timeIntervalSince1970: 1_793_000_000), subsystem: "Fixture", message: "Sample sanitized connection failure.", count: 2)])
}

/// Isolates the layout/config lookup performed by AppDelegate construction.
@MainActor private func withDiagnosticDirectory(_ body: () async throws -> Void) async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("koi-diagnostics-\(UUID())")
    try Paths.ensurePrivateDirectory(path)
    let previous = ProcessInfo.processInfo.environment["KOI_DIR"]
    setenv("KOI_DIR", path.path, 1)
    defer {
        if let previous { setenv("KOI_DIR", previous, 1) } else { unsetenv("KOI_DIR") }
        try? FileManager.default.removeItem(at: path)
    }
    try await body()
}
