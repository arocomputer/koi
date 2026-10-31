import Foundation
import Testing
import UserNotifications
@testable import Koi

/// Every transition is a server event; no notification center or agent catalog is used.
@Suite @MainActor struct ActivityTests {
    @Test func coalescedCompletionSurvivesIdenticalSnapshotStatuses() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        var feed = AgentFeed()
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        // App never observes the intermediate working snapshot, or even a done status.
        feed.report(.working); feed.report(.done); feed.report(.idle)
        feed.active = false
        var completed = 0
        await center.consume(snapshot: [.local: feed.state], config: enabled, onAgentCompletion: { _ in completed += 1 })
        #expect(completed == 1 && center.completions.count == 1)
        #expect(recorder.sent.map(\.status) == [.done])
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.count == 1)
        center.acknowledge(.init(endpoint: .local, pane: "pane"))
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(center.completions.isEmpty)
    }

    @Test func baselineRestartAndJournalGapsAreSilent() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        var feed = AgentFeed()
        feed.report(.working); feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.isEmpty && center.completions.isEmpty)
        feed.epoch = "restarted"
        feed.report(.working); feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.isEmpty)
        feed.report(.working); feed.report(.blocked); feed.report(.done)
        feed.events = Array(feed.events.suffix(1))
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(center.historyGap && recorder.sent.isEmpty)
        feed.report(.working); feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.map(\.status) == [.done], "tracking resumes after the gap")
    }

    @Test func unknownAgentNamesWorkAndUnregisteredCatalogNamesStaySilent() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        var feed = AgentFeed()
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.first?.program == "my-new-agent")
        var ordinary = AgentFeed()
        ordinary.epoch = "ordinary-epoch"
        ordinary.registered = false
        ordinary.name = "claude"
        await center.consume(snapshot: [.local: ordinary.state], config: enabled)
        ordinary.report(.working); ordinary.report(.done)
        await center.consume(snapshot: [.local: ordinary.state], config: enabled)
        #expect(recorder.sent.count == 1)
    }

    @Test func sameNameReplacementAndNewTurnsDoNotReplayEarlierRuns() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        var feed = AgentFeed()
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.done)
        let stale = feed.state
        // New session, same executable name. Old completion is not this session's.
        feed.session = "new-session"
        feed.report(.working)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(center.completions.isEmpty && recorder.sent.isEmpty)
        feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(center.completions.count == 1 && recorder.sent.count == 1)
        await center.consume(snapshot: [.local: stale], config: enabled)
        #expect(center.completions.count == 1 && recorder.sent.count == 1, "an older window cannot rewind the current run")
        feed.report(.working); feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.count == 2, "same-name second turn has independent identity")
    }

    @Test func machinesAndViewedPanesHaveIndependentUnreadState() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { true })
        let remote = Endpoint.ssh("fixture")
        var feed = AgentFeed()
        await center.consume(snapshot: [.local: feed.state, remote: feed.state])
        feed.report(.working); feed.report(.done)
        var completed: [ActivityItem.ID] = []
        await center.consume(snapshot: [.local: feed.state, remote: feed.state],
                             viewedPanes: [.init(endpoint: .local, pane: "pane")], onAgentCompletion: { completed.append($0.id) })
        #expect(completed == [.init(endpoint: remote, pane: "pane")])
        #expect(center.completions.count == 1 && recorder.sent.isEmpty)
        await center.consume(snapshot: [:])
        #expect(center.completions.isEmpty && center.activities.isEmpty)
        await center.consume(snapshot: [remote: feed.state], config: enabled)
        #expect(recorder.sent.isEmpty, "reconnect without a retained baseline is silent")
    }

    @Test func resolvedBlockedEventsDoNotNotifyFromACoalescedBatch() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        var feed = AgentFeed()
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.blocked); feed.report(.working)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.isEmpty && center.completions.isEmpty)
    }

    @Test func focusedAndDisabledEventsNeverBecomeCatchUpAlerts() async {
        let recorder = ActivityRecorder()
        var focused = true
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { focused })
        var feed = AgentFeed()
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.blocked)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        focused = false
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.error)
        await center.consume(snapshot: [.local: feed.state], config: Config())
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.isEmpty && recorder.requests == 0)
        feed.report(.working); feed.report(.blocked)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.map(\.status) == [.blocked])
    }

    @Test func authorizationIsExplicitAndVisitingCancelsPendingDelivery() async {
        let recorder = ActivityRecorder()
        recorder.status = .notDetermined
        var feed = AgentFeed()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.requests == 0 && recorder.sent.isEmpty)
        #expect(await center.requestAuthorizationFromUserAction())
        #expect(recorder.requests == 1 && recorder.sent.isEmpty)
        var delivery = recorder.delivery
        var pending: ActivityCenter?
        delivery.authorization = {
            pending?.acknowledge(.init(endpoint: .local, pane: "pane"))
            return .authorized
        }
        let next = ActivityCenter(delivery: delivery, isAppFocused: { false })
        pending = next
        await next.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.done)
        await next.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.isEmpty && next.completions.isEmpty)
    }

    @Test(arguments: [false, true]) func idlePreservesPendingCompletionButViewingCancelsIt(viewed: Bool) async {
        let recorder = ActivityRecorder()
        var feed = AgentFeed()
        var pending: ActivityCenter?
        var delivery = recorder.delivery
        delivery.authorization = {
            feed.report(.idle)
            await pending?.consume(snapshot: [.local: feed.state], config: self.enabled,
                                   viewedPanes: viewed ? [.init(endpoint: .local, pane: "pane")] : [])
            return .authorized
        }
        let center = ActivityCenter(delivery: delivery, isAppFocused: { false })
        pending = center
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.done)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(recorder.sent.count == (viewed ? 0 : 1))
        #expect(center.completions.isEmpty == viewed)
    }

    @Test func deliveryFailureIsVisibleAndDoesNotReplay() async {
        let recorder = ActivityRecorder()
        var delivery = recorder.delivery
        delivery.send = { _ in throw CocoaError(.fileWriteNoPermission) }
        let center = ActivityCenter(delivery: delivery, isAppFocused: { false })
        var feed = AgentFeed()
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        feed.report(.working); feed.report(.error)
        await center.consume(snapshot: [.local: feed.state], config: enabled)
        #expect(center.notificationError != nil)
        #expect(center.reportingAgents.first?.adapter == "fixture-v1")
    }

    private var enabled: Config {
        var config = Config()
        config.notifyBlocked = true; config.notifyDone = true; config.notifyError = true
        return config
    }
}

private struct AgentFeed {
    var epoch = "epoch"
    var session = "session"
    var name = "my-new-agent"
    var run: UInt64 = 0
    var sequence: UInt64 = 0
    var status: Wire.Status = .idle
    var registered = true
    var active = true
    var events: [Wire.AgentEvent] = []
    mutating func report(_ next: Wire.Status) {
        if next == .working && (status == .idle || status == .done || status == .error) { run += 1 }
        status = next; sequence += 1
        events.append(.init(sequence: sequence, session: session, run: run, status: next))
    }
    var state: Wire.State {
        var pane = Wire.PaneInfo(id: "pane", pid: 42, title: "Task", cwd: "/fixture", program: name,
                                 shell: "sh", fullscreen: false, status: status)
        pane.agentEpoch = epoch; pane.agentSequence = sequence; pane.agentEvents = events
        if registered {
            pane.agent = .init(active: active, id: session, name: name, adapter: "fixture-v1", run: run, lastReport: 100)
        }
        return .init(items: [.tab(.init(id: "tab", panes: [pane], layout: .pane("pane")))])
    }
}

@MainActor private final class ActivityRecorder {
    var status: UNAuthorizationStatus = .authorized
    var requests = 0
    var sent: [ActivityItem] = []
    var delivery: ActivityDelivery {
        .init(authorization: { self.status }, requestAuthorization: {
            self.requests += 1; self.status = .authorized; return true
        }, send: { self.sent.append($0) })
    }
}
