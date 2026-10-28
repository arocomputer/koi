import Foundation
import Testing
@testable import Koi

/// A controllable probe that never accesses hardware or the network.
private actor DeviceProbeFixture {
    private var continuations: [CheckedContinuation<String?, Never>] = []
    private(set) var calls = 0

    func lookup() async -> String? {
        calls += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func finish(_ value: String?) { continuations.removeFirst().resume(returning: value) }
}

/// Give asynchronous state changes a bounded opportunity to arrive.
@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Suite struct DeviceIconsTests {
    @Test func defaultProbeIsDisabledInXCTest() async {
        guard Bundle.main.bundleURL.pathExtension == "xctest" else { return }
        #expect(await DeviceProbe.defaultLookup(.local) == nil)
        #expect(await DeviceProbe.defaultLookup(.ssh("fixture")) == nil)
    }

    @Test func mapsReportedFamilies() {
        #expect(DeviceProbe.symbol(model: "Mac mini") == "macmini")
        #expect(DeviceProbe.symbol(model: "Mac Studio") == "macstudio")
        #expect(DeviceProbe.symbol(model: "MacBook Pro") == "macbook.gen2")
        #expect(DeviceProbe.symbol(model: "MacBook Air") == "macbook.gen2")
        #expect(DeviceProbe.symbol(model: "Mac Pro") == "macpro.gen3")
        #expect(DeviceProbe.symbol(model: "iMac") == "desktopcomputer")
        #expect(DeviceProbe.symbol(model: "mini") == nil)
        #expect(DeviceProbe.symbol(output: "system_profiler failed") == nil)
        #expect(DeviceProbe.symbol(profilerJSON: Data(#"{"SPHardwareDataType":[{"machine_name":"Mac mini","serial_number":"ignored"}]}"#.utf8)) == "macmini")
        #expect(DeviceProbe.symbol(output: "Linux\n") == "server.rack")
        #expect(DeviceProbe.symbol(output: "\n") == nil)
    }

    @Test @MainActor func cachedLookupIsImmediateDeduplicatedAndRetriesFailures() async throws {
        let fixture = DeviceProbeFixture(), endpoint = Endpoint.ssh("mini")
        var persisted: [String: String] = [:]
        let icons = DeviceIcons(symbols: ["ssh:mini": "macstudio"], lookup: { _ in await fixture.lookup() },
                                scope: { URL(fileURLWithPath: "/fixture/device-icons") },
                                persist: { persisted[$0] = $1 })
        icons.probe(endpoint)
        icons.probe(endpoint)
        #expect(icons.symbol(for: endpoint) == "macstudio")
        try #require(await eventually { await fixture.calls == 1 })
        #expect(await fixture.calls == 1)
        await fixture.finish(nil)
        #expect(icons.symbol(for: endpoint) == "macstudio")
        try #require(await eventually { icons.probe(endpoint); return await fixture.calls == 2 })
        await fixture.finish("macmini")
        try #require(await eventually { icons.symbol(for: endpoint) == "macmini" })
        #expect(persisted["ssh:mini"] == "macmini")
        icons.probe(endpoint)
        #expect(await fixture.calls == 2)
    }

    @Test @MainActor func removedEndpointCannotPublishAnOldResult() async throws {
        let fixture = DeviceProbeFixture(), endpoint = Endpoint.ssh("host")
        let icons = DeviceIcons(symbols: [:], lookup: { _ in await fixture.lookup() },
                                scope: { URL(fileURLWithPath: "/fixture/device-icons") }, persist: { _, _ in })
        icons.probe(endpoint)
        try #require(await eventually { await fixture.calls == 1 })
        icons.remove(endpoint)
        icons.probe(endpoint)
        try #require(await eventually { await fixture.calls == 2 })
        await fixture.finish("macmini")
        for _ in 0..<10 { await Task.yield() }
        #expect(icons.symbol(for: endpoint) == "desktopcomputer")
        await fixture.finish("macstudio")
        try #require(await eventually { icons.symbol(for: endpoint) == "macstudio" })
    }

    @Test @MainActor func cacheFollowsLayoutScopeAndRejectsLateResults() async throws {
        let fixture = DeviceProbeFixture(), endpoint = Endpoint.ssh("host")
        let first = URL(fileURLWithPath: "/fixture/one"), second = URL(fileURLWithPath: "/fixture/two")
        var scope = first
        var writes: [String] = []
        let icons = DeviceIcons(symbols: ["ssh:host": "macmini"], lookup: { _ in await fixture.lookup() },
                                scope: { scope }, load: { ["ssh:host": "not-a-symbol"] },
                                persist: { _, value in if let value { writes.append(value) } })
        icons.probe(endpoint)
        try #require(await eventually { await fixture.calls == 1 })
        scope = second
        #expect(icons.symbol(for: endpoint) == "desktopcomputer")
        await fixture.finish("macstudio")
        for _ in 0..<10 { await Task.yield() }
        #expect(icons.symbol(for: endpoint) == "desktopcomputer")
        #expect(writes.isEmpty)
        icons.probe(endpoint)
        try #require(await eventually { await fixture.calls == 2 })
        await fixture.finish("macpro.gen3")
        try #require(await eventually { icons.symbol(for: endpoint) == "macpro.gen3" })
        #expect(writes == ["macpro.gen3"])
    }
}
