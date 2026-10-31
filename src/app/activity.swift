import AppKit
import SwiftUI
import Foundation
import Observation
import UserNotifications

/// Current non-idle work, identified by machine and pane rather than tab position.
struct ActivityItem: Identifiable, Equatable {
    struct ID: Hashable {
        var endpoint: Endpoint
        var pane: String
    }

    var id: ID
    var tab: String
    var title: String
    var program: String
    var status: Wire.Status
    var changedAt: Date
}

/// Injectable notification I/O. Constructing the system delivery never asks permission.
@MainActor struct ActivityDelivery {
    var authorization: () async -> UNAuthorizationStatus
    var requestAuthorization: () async throws -> Bool
    var send: (ActivityItem) async throws -> Void

    /// System access is deferred until an explicit refresh, UI action or transition.
    static var system: Self {
        Self(
            authorization: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
            requestAuthorization: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            },
            send: { item in
                let content = UNMutableNotificationContent()
                switch item.status {
                case .blocked: content.title = "Koi: input needed"
                case .done: content.title = "Koi: agent finished"
                case .error: content.title = "Koi: agent failed"
                default: return
                }
                content.body = item.title.isEmpty ? item.program : item.title
                content.userInfo = ["tab": item.tab, "pane": item.id.pane]
                if case .ssh(let host) = item.id.endpoint { content.userInfo["host"] = host }
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            })
    }
}

/// Feed complete snapshots of every connected machine. First observations are silent;
/// repeated statuses, removed panes and suppressed transitions never produce catch-up alerts.
@MainActor @Observable final class ActivityCenter {
    private(set) var activities: [ActivityItem] = []
    /// Unread agent completions survive idle status until visited or work starts again.
    private(set) var completions: [ActivityItem.ID: ActivityItem] = [:]
    private struct Cursor { var epoch: String; var sequence: UInt64 }
    @ObservationIgnored private var cursors: [ActivityItem.ID: Cursor] = [:]
    @ObservationIgnored private var lastPanes: [ActivityItem.ID: Wire.PaneInfo] = [:]
    @ObservationIgnored private var runs: [ActivityItem.ID: String] = [:]
    /// A replay gap is shown rather than fabricating transitions from a snapshot.
    private(set) var historyGap = false
    private(set) var reportingAgents: [Wire.AgentSession] = []

    func acknowledge(_ id: ActivityItem.ID) {
        completions[id] = nil
        // Reading a pane also cancels any system alert still waiting for authorization.
        revisions[id] = UUID()
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var notificationError: String?
    @ObservationIgnored private let delivery: ActivityDelivery
    @ObservationIgnored private let isAppFocused: () -> Bool
    @ObservationIgnored private var previous: [ActivityItem.ID: Wire.Status] = [:]
    @ObservationIgnored private var revisions: [ActivityItem.ID: UUID] = [:]

    /// Tests must inject delivery; no permission or notification I/O occurs at initialization.
    init(delivery: ActivityDelivery = .system,
         isAppFocused: @escaping () -> Bool = { NSApp?.isActive ?? false }) {
        self.delivery = delivery
        self.isAppFocused = isAppFocused
    }

    /// Reads existing authorization without opening a permission prompt.
    func refreshAuthorization() async {
        authorization = await delivery.authorization()
    }

    /// Wire only to an explicit user action such as Enable Notifications.
    @discardableResult func requestAuthorizationFromUserAction() async -> Bool {
        notificationError = nil
        do {
            let granted = try await delivery.requestAuthorization()
            await refreshAuthorization()
            return granted
        } catch {
            notificationError = error.localizedDescription
            return false
        }
    }

    /// Omitted machines/panes are removed. Keep disconnected machines' last states in the
    /// input if their activity should remain visible. Call after any workspace state changes.
    func consume(snapshot: [Endpoint: Wire.State], config: Config = .current, now: Date = Date(),
                 viewedPanes: Set<ActivityItem.ID> = [],
                 onAgentCompletion: ((ActivityItem) -> Void)? = nil) async {
        let oldItems = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        var next: [ActivityItem.ID: Wire.Status] = [:]
        var nextRuns: [ActivityItem.ID: String] = [:]
        var reporting: [Wire.AgentSession] = []
        var completed: [ActivityItem] = []
        var nextRevisions: [ActivityItem.ID: UUID] = [:]
        var items: [ActivityItem] = []
        var notices: [(ActivityItem, UUID)] = []
        for (endpoint, state) in snapshot {
            for tab in state.tabs {
                for incoming in tab.panes {
                    let id = ActivityItem.ID(endpoint: endpoint, pane: incoming.id)
                    // Multiple windows can publish the same endpoint at different
                    // revisions. Never let an older window rewind lifecycle state.
                    let pane: Wire.PaneInfo
                    if let cached = lastPanes[id], cached.agentEpoch == incoming.agentEpoch,
                       (cached.agentSequence ?? 0) > (incoming.agentSequence ?? 0) {
                        pane = cached
                    } else { pane = incoming }
                    lastPanes[id] = pane
                    let old = previous[id]
                    next[id] = pane.status
                    let run = pane.agent.map { "\($0.id):\($0.run)" }
                    if let run { nextRuns[id] = run }
                    else { nextRuns[id] = runs[id] }
                    let sameRun = nextRuns[id] == runs[id]
                    if !sameRun || pane.status == .working || viewedPanes.contains(id) {
                        completions[id] = nil
                    }
                    if let agent = pane.agent, agent.active { reporting.append(agent) }
                    var events: [Wire.AgentEvent] = []
                    if let epoch = pane.agentEpoch, let sequence = pane.agentSequence {
                        if let cursor = cursors[id], cursor.epoch == epoch, sequence >= cursor.sequence {
                            let unseen = (pane.agentEvents ?? []).filter { $0.sequence > cursor.sequence }
                            // Never bridge a truncated journal. Rebaseline and expose the gap.
                            if sequence > cursor.sequence && unseen.first?.sequence != cursor.sequence + 1 {
                                historyGap = true
                            } else {
                                events = unseen.filter { $0.session == pane.agent?.id && $0.run == pane.agent?.run }
                            }
                        }
                        if cursors[id]?.epoch != epoch || sequence >= (cursors[id]?.sequence ?? 0) {
                            cursors[id] = Cursor(epoch: epoch, sequence: sequence)
                        }
                    }
                    let revision = sameRun && events.isEmpty && old == pane.status ? (revisions[id] ?? UUID()) : UUID()
                    nextRevisions[id] = revision
                    let item = ActivityItem(id: id, tab: tab.id,
                                            title: tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? pane.title,
                                            program: pane.program, status: pane.status,
                                            changedAt: old == pane.status ? (oldItems[id]?.changedAt ?? now) : now)
                    if pane.status != .idle { items.append(item) }
                    for event in events.filter({ $0.status == .done || $0.status == .blocked || $0.status == .error }).suffix(1) where !viewedPanes.contains(id) {
                        var eventItem = item
                        eventItem.program = pane.agent?.name ?? pane.program
                        eventItem.status = event.status
                        if event.status == .done {
                            completions[id] = eventItem
                            completed.append(eventItem)
                        }
                        let enabled = switch event.status {
                        case .blocked: config.notifyBlocked
                        case .done: config.notifyDone
                        case .error: config.notifyError
                        default: false
                        }
                        if enabled { notices.append((eventItem, revision)) }
                    }

                }
            }
        }
        completions = completions.filter { next[$0.key] != nil }
        cursors = cursors.filter { next[$0.key] != nil }
        lastPanes = lastPanes.filter { next[$0.key] != nil }
        runs = nextRuns
        reportingAgents = reporting
        previous = next
        revisions = nextRevisions
        activities = items.sorted {
            if $0.changedAt != $1.changedAt { return $0.changedAt > $1.changedAt }
            let left = String(describing: $0.id.endpoint) + $0.id.pane
            let right = String(describing: $1.id.endpoint) + $1.id.pane
            return left < right
        }
        for item in completed { onAgentCompletion?(item) }
        guard !notices.isEmpty, !(config.quietWhenFocused && isAppFocused()) else { return }
        await refreshAuthorization()
        guard authorization == .authorized || authorization == .provisional else { return }
        for (item, revision) in notices {
            guard revisions[item.id] == revision, !(config.quietWhenFocused && isAppFocused()) else { continue }
            do { try await delivery.send(item) }
            catch { notificationError = error.localizedDescription }
        }
    }
}

/// Authorization is requested only from its button; activity is already tracked
/// independently of notification permission and delivery preferences.
struct ActivitySettingsView: View {
    let center: ActivityCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notification Permission").font(.headline)
            Text(permission).font(.callout).foregroundStyle(.secondary)
            Button("Enable Notifications…") { Task { await center.requestAuthorizationFromUserAction() } }
                .disabled(center.authorization == .authorized)
            if let error = center.notificationError { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Agent Reporting").font(.headline).padding(.top, 8)
            Text("Installed hooks are configuration only. Agents appear here after Koi accepts a valid lifecycle report.")
                .font(.callout).foregroundStyle(.secondary)
            if reportingAgents.isEmpty { Text("No verified reports from active agents.").foregroundStyle(.secondary) }
            ForEach(reportingAgents, id: \.id) { agent in
                VStack(alignment: .leading) {
                    Text(agent.name + " · " + (agent.adapter ?? "custom integration"))
                    Text("Last report: " + Date(timeIntervalSince1970: agent.lastReport).formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if historyGap { Text("Some agent history expired during a disconnect. Koi resumed tracking without sending catch-up alerts.").font(.caption).foregroundStyle(.secondary) }
            Text("Activity").font(.headline).padding(.top, 8)
            if center.activities.isEmpty { Text("No programs are reporting activity.").foregroundStyle(.secondary) }
            ForEach(center.activities) { item in
                HStack {
                    Text(item.program.isEmpty ? "Terminal" : item.program)
                    Spacer()
                    Text(item.status == .blocked ? "Waiting for input" : item.status.rawValue.capitalized).foregroundStyle(.secondary)
                }.font(.callout)
            }
        }
        .task { await center.refreshAuthorization() }
    }
    private var permission: String {
        switch center.authorization {
        case .notDetermined: "Notifications are optional. Choose Enable to allow system notifications."
        case .denied: "System notifications are disabled. You can allow Koi in System Settings → Notifications."
        case .authorized, .provisional, .ephemeral: "System notifications are allowed. Choose which events to receive above."
        @unknown default: "Notification permission is unavailable."
        }
    }
}

/// Shared completion mark for tab tiles and individual split-pane icons.
struct AgentCompletionDot: View {
    var body: some View {
        Circle().fill(.yellow)
            .frame(width: 5, height: 5)
            .overlay { Circle().stroke(Theme.current.backgroundColor, lineWidth: 1) }
            .accessibilityHidden(true)
    }
}
