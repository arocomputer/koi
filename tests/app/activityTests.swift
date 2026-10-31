import Foundation
import Testing
import UserNotifications
@testable import Koi

/// No test accesses UNUserNotificationCenter: every authorization and delivery is recorded.
@Suite @MainActor struct ActivityTests {
    @Test func snapshotsTrackAllMachinesWithoutBaselineOrDuplicateAlerts() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        let remote = Endpoint.ssh("fixture")
        await center.consume(snapshot: [.local: state(.working), remote: state(.blocked)], config: enabled)
        #expect(center.activities.count == 2)
        #expect(recorder.sent.isEmpty)
        await center.consume(snapshot: [.local: state(.done), remote: state(.error)], config: enabled)
        #expect(Set(recorder.sent.map(\.status)) == [.done, .error])
        #expect(Set(recorder.sent.map(\.id.endpoint)) == [.local, remote])
        await center.consume(snapshot: [.local: state(.done), remote: state(.error)], config: enabled)
        #expect(recorder.sent.count == 2)
        #expect(recorder.requests == 0)
    }

    @Test func focusedAndDisabledTransitionsNeverBecomeCatchUpAlerts() async {
        let recorder = ActivityRecorder()
        var focused = true
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { focused })
        await center.consume(snapshot: [.local: state(.working)], config: enabled)
        await center.consume(snapshot: [.local: state(.blocked)], config: enabled)
        focused = false
        await center.consume(snapshot: [.local: state(.blocked)], config: enabled)
        #expect(recorder.sent.isEmpty)
        await center.consume(snapshot: [.local: state(.error)], config: Config())
        await center.consume(snapshot: [.local: state(.error)], config: enabled)
        #expect(recorder.sent.isEmpty)
        await center.consume(snapshot: [.local: state(.working)], config: enabled)
        await center.consume(snapshot: [.local: state(.blocked)], config: enabled)
        #expect(recorder.sent.map(\.status) == [.blocked])
    }

    @Test func authorizationIsOnlyRequestedByTheExplicitUIAction() async {
        let recorder = ActivityRecorder()
        recorder.status = .notDetermined
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        await center.consume(snapshot: [.local: state(.working)], config: enabled)
        await center.consume(snapshot: [.local: state(.done)], config: enabled)
        #expect(recorder.requests == 0)
        #expect(recorder.sent.isEmpty)
        #expect(await center.requestAuthorizationFromUserAction())
        #expect(recorder.requests == 1)
        #expect(center.authorization == .authorized)
        #expect(recorder.sent.isEmpty)
    }

    @Test func idleAndRemovedPanesLeaveTheCurrentList() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        let first = Date(timeIntervalSince1970: 10)
        await center.consume(snapshot: [.local: state(.working)], now: first)
        await center.consume(snapshot: [.local: state(.working)], now: first.addingTimeInterval(5))
        #expect(center.activities.first?.changedAt == first)
        await center.consume(snapshot: [.local: state(.idle)])
        #expect(center.activities.isEmpty)
        await center.consume(snapshot: [.local: state(.error)], config: enabled)
        await center.consume(snapshot: [:], config: enabled)
        #expect(center.activities.isEmpty)
        let count = recorder.sent.count
        await center.consume(snapshot: [.local: state(.error)], config: enabled)
        #expect(recorder.sent.count == count)
    }

    @Test func deliveryFailuresAreVisibleWithoutReplayingTheTransition() async {
        let recorder = ActivityRecorder()
        var delivery = recorder.delivery
        delivery.send = { _ in throw CocoaError(.fileWriteNoPermission) }
        let center = ActivityCenter(delivery: delivery, isAppFocused: { false })
        await center.consume(snapshot: [.local: state(.working)], config: enabled)
        await center.consume(snapshot: [.local: state(.error)], config: enabled)
        #expect(center.notificationError != nil)
        #expect(center.activities.first?.status == .error)
    }

    @Test func aNewerSnapshotInvalidatesAnAlertWaitingForAuthorization() async {
        let recorder = ActivityRecorder()
        var center: ActivityCenter?
        var delivery = recorder.delivery
        delivery.authorization = {
            await center?.consume(snapshot: [:])
            return .authorized
        }
        let activity = ActivityCenter(delivery: delivery, isAppFocused: { false })
        center = activity
        await activity.consume(snapshot: [.local: state(.working)], config: enabled)
        await activity.consume(snapshot: [.local: state(.blocked)], config: enabled)
        #expect(activity.activities.isEmpty)
        #expect(recorder.sent.isEmpty)
    }

    @Test func ordinaryProgramsNeverProduceAgentNoticesOrBadges() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        var completions = 0
        await center.consume(snapshot: [.local: state(.working, program: "make")], config: enabled)
        await center.consume(snapshot: [.local: state(.done, program: "make")], config: enabled,
                             onAgentCompletion: { _ in completions += 1 })
        #expect(completions == 0 && recorder.sent.isEmpty && center.completions.isEmpty)
        #expect(center.activities.first?.program == "make", "ordinary activity is still searchable")
    }

    @Test func agentCompletionsAreUnreadPerPaneAndMachineUntilVisited() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { true })
        let remote = Endpoint.ssh("fixture")
        let localID = ActivityItem.ID(endpoint: .local, pane: "pane")
        let remoteID = ActivityItem.ID(endpoint: remote, pane: "pane")
        var completed: [ActivityItem.ID] = []
        await center.consume(snapshot: [.local: state(.working), remote: state(.working)])
        await center.consume(snapshot: [.local: state(.done), remote: state(.done)],
                             viewedPanes: [localID], onAgentCompletion: { completed.append($0.id) })
        #expect(completed == [remoteID])
        #expect(Set(center.completions.keys) == [remoteID])
        #expect(recorder.sent.isEmpty, "in-app cues do not require system notification permission")
        await center.consume(snapshot: [.local: state(.done), remote: state(.idle, program: "")],
                             viewedPanes: [localID], onAgentCompletion: { completed.append($0.id) })
        #expect(Set(center.completions.keys) == [remoteID], "returning to a shell preserves unread completion")
        center.acknowledge(remoteID)
        await center.consume(snapshot: [.local: state(.done), remote: state(.idle, program: "")])
        #expect(center.completions.isEmpty && completed.count == 1, "no replay after acknowledgement")
        await center.consume(snapshot: [remote: state(.working)])
        await center.consume(snapshot: [remote: state(.done)], onAgentCompletion: { completed.append($0.id) })
        #expect(completed.count == 2 && center.completions[remoteID] != nil)
        await center.consume(snapshot: [:])
        #expect(center.completions.isEmpty)
    }

    @Test func initialDoneAndProgramChangesAreSilent() async {
        let recorder = ActivityRecorder()
        let center = ActivityCenter(delivery: recorder.delivery, isAppFocused: { false })
        var completions = 0
        await center.consume(snapshot: [.local: state(.done, program: "codex")], config: enabled,
                             onAgentCompletion: { _ in completions += 1 })
        await center.consume(snapshot: [.local: state(.working, program: "make")], config: enabled)
        await center.consume(snapshot: [.local: state(.done, program: "claude")], config: enabled,
                             onAgentCompletion: { _ in completions += 1 })
        #expect(completions == 0 && recorder.sent.isEmpty && center.completions.isEmpty)
    }

    private var enabled: Config {
        var config = Config()
        config.notifyBlocked = true
        config.notifyDone = true
        config.notifyError = true
        return config
    }

    /// Same IDs deliberately occur on both machines to protect identity scoping.
    private func state(_ status: Wire.Status, program: String = "agent") -> Wire.State {
        let pane = Wire.PaneInfo(id: "pane", pid: 0, title: "Task", cwd: "/fixture", program: program,
                                 shell: "sh", fullscreen: false, status: status)
        return Wire.State(items: [.tab(.init(id: "tab", panes: [pane], layout: .pane(pane.id)))])
    }
}

/// An in-memory notification sink; never constructs the system notification center.
@MainActor private final class ActivityRecorder {
    var status: UNAuthorizationStatus = .authorized
    var requests = 0
    var sent: [ActivityItem] = []
    var delivery: ActivityDelivery {
        ActivityDelivery(authorization: { self.status }, requestAuthorization: {
            self.requests += 1
            self.status = .authorized
            return true
        }, send: { self.sent.append($0) })
    }
}
