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
                case .done: content.title = "Koi: task finished"
                case .error: content.title = "Koi: task failed"
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
    func consume(snapshot: [Endpoint: Wire.State], config: Config = .current, now: Date = Date()) async {
        let oldItems = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        var next: [ActivityItem.ID: Wire.Status] = [:]
        var nextRevisions: [ActivityItem.ID: UUID] = [:]
        var items: [ActivityItem] = []
        var notices: [(ActivityItem, UUID)] = []
        for (endpoint, state) in snapshot {
            for tab in state.tabs {
                for pane in tab.panes {
                    let id = ActivityItem.ID(endpoint: endpoint, pane: pane.id)
                    let old = previous[id]
                    next[id] = pane.status
                    let revision = old == pane.status ? (revisions[id] ?? UUID()) : UUID()
                    nextRevisions[id] = revision
                    guard pane.status != .idle else { continue }
                    let item = ActivityItem(id: id, tab: tab.id,
                                            title: tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? pane.title,
                                            program: pane.program, status: pane.status,
                                            changedAt: old == pane.status ? (oldItems[id]?.changedAt ?? now) : now)
                    items.append(item)
                    let enabled = switch pane.status {
                    case .blocked: config.notifyBlocked
                    case .done: config.notifyDone
                    case .error: config.notifyError
                    default: false
                    }
                    if old != nil, old != pane.status, enabled { notices.append((item, revision)) }
                }
            }
        }
        previous = next
        revisions = nextRevisions
        activities = items.sorted {
            if $0.changedAt != $1.changedAt { return $0.changedAt > $1.changedAt }
            let left = String(describing: $0.id.endpoint) + $0.id.pane
            let right = String(describing: $1.id.endpoint) + $1.id.pane
            return left < right
        }
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
