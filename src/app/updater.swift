import AppKit
import Observation
import Sparkle
import SwiftUI

/// What the update toast says and offers at each step of an update. Pure state:
/// the Sparkle driver below feeds it, the view reads it, and tests drive it
/// without Sparkle. Every transition has one owner, the driver; the view only
/// calls `accept`, `decline` and `restart`.
@MainActor @Observable final class UpdateToastModel {
    enum Phase: Equatable {
        case hidden
        case checking
        case available(version: String)
        case downloading(version: String, fraction: Double?)
        case extracting(version: String)
        /// Downloaded and verified; installing needs a restart, or happens when Koi quits.
        case ready(version: String)
        case installing(version: String)
        case upToDate
        case failed(String)
    }

    private(set) var phase: Phase = .hidden
    /// Whether the person asked for this check. A background check that finds
    /// nothing, or fails, says nothing.
    private(set) var userInitiated = false

    /// What the buttons do; set by the driver for the step being shown.
    @ObservationIgnored var onAccept: (() -> Void)?
    @ObservationIgnored var onDecline: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    func show(_ phase: Phase, userInitiated: Bool? = nil) {
        if let userInitiated { self.userInitiated = userInitiated }
        self.phase = phase
    }

    func hide() {
        phase = .hidden
        userInitiated = false
        onAccept = nil
        onDecline = nil
        onCancel = nil
    }

    func clearActions() {
        onAccept = nil
        onDecline = nil
        onCancel = nil
    }

    func accept() { let action = onAccept; clearActions(); action?() }
    func decline() { let action = onDecline; clearActions(); action?() }
    func cancel() { let action = onCancel; clearActions(); action?() }

    /// Progress through a download whose total length may not be known.
    func downloaded(_ bytes: UInt64, of expected: UInt64?, version: String) {
        guard let expected, expected > 0 else { show(.downloading(version: version, fraction: nil)); return }
        show(.downloading(version: version, fraction: min(1, Double(bytes) / Double(expected))))
    }
}

/// Sparkle's user driver with Koi's face: it never opens a window, and every
/// question becomes a button on the toast. Sparkle does the work (download,
/// signature check, replacing the app, relaunching); this only says so.
@MainActor final class ToastUpdateDriver: NSObject, SPUUserDriver {
    let model: UpdateToastModel
    private var version = ""
    private var expected: UInt64?
    private var received: UInt64 = 0
    private var acknowledge: (() -> Void)?
    /// Test hook for the development app: take every offer and restart at once.
    private let automatic: Bool
    /// How long "up to date" and an error stay on screen; tests shorten them.
    var noticeSeconds: Double = 3
    var errorSeconds: Double = 8

    init(model: UpdateToastModel, automatic: Bool = false) {
        self.model = model
        self.automatic = automatic
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Checking for updates is on by default and can be turned off in Settings;
        // no profile of this Mac is ever sent.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.clearActions()
        model.show(.checking, userInitiated: true)
        model.onCancel = { [model] in model.hide(); cancellation() }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        offer(version: appcastItem.displayVersionString, reply: reply)
    }

    /// An update was found: put the question on the toast.
    func offer(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.version = version
        model.clearActions()
        model.show(.available(version: version))
        model.onAccept = { reply(.install) }
        model.onDecline = { [model] in model.hide(); reply(.dismiss) }
        if automatic { model.accept() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard model.userInitiated else { acknowledgement(); return }
        model.clearActions()
        model.show(.upToDate)
        finishSoon(acknowledgement, after: noticeSeconds)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard model.userInitiated || model.phase != .hidden else { acknowledgement(); return }
        model.clearActions()
        model.show(.failed(Self.message(for: error)))
        finishSoon(acknowledgement, after: errorSeconds)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        received = 0
        expected = nil
        model.clearActions()
        model.show(.downloading(version: version, fraction: nil))
        model.onCancel = { [model] in model.hide(); cancellation() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        model.downloaded(received, of: expected, version: version)
    }

    func showDownloadDidStartExtractingUpdate() {
        model.onCancel = nil
        model.show(.extracting(version: version))
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.clearActions()
        model.show(.ready(version: version))
        model.onAccept = { reply(.install) }
        // Later: the update installs when Koi next quits. Sessions live in the server, so nothing is lost.
        model.onDecline = { [model] in model.hide(); reply(.dismiss) }
        if automatic { model.accept() }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        model.show(.installing(version: version))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        model.hide()
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // A message already on screen (up to date, an error) finishes on its own timer.
        switch model.phase {
        case .upToDate, .failed: break
        default: model.hide()
        }
    }

    /// Leaves a message up long enough to read, then clears it and tells Sparkle.
    private func finishSoon(_ done: @escaping () -> Void, after seconds: Double) {
        acknowledge = done
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let done = self.acknowledge else { return }
            self.acknowledge = nil
            self.model.hide()
            done()
        }
    }

    /// Sparkle's errors are written for developers; say what happened plainly.
    static func message(for error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return "Couldn't reach the update server. Check your connection." }
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { return "Koi is up to date." }
        return "The update didn't install: \(nsError.localizedDescription)"
    }
}

/// Owns Sparkle for the whole app. Updates are on only in a build that carries a
/// feed address and the key its updates are signed with (see scripts/bundle.sh);
/// the development app and any local build do not, and never touch the network.
@MainActor final class AppUpdater: NSObject {
    let model = UpdateToastModel()
    private var updater: SPUUpdater?
    private let presenter: UpdateToastPresenter

    /// True when this build can update itself.
    let isConfigured: Bool
    /// Development app only: look for an update at launch and take it, so the
    /// whole path can be exercised without a click (see CONTRIBUTING).
    private let checkAtLaunch: Bool

    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isConfigured = feed?.isEmpty == false && key?.isEmpty == false
        presenter = UpdateToastPresenter(model: model)
        #if KOID
        let automatic = ProcessInfo.processInfo.environment["KOI_UPDATE_AUTOACCEPT"] == "1"
        #else
        let automatic = false
        #endif
        checkAtLaunch = automatic
        super.init()
        guard isConfigured else { return }
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                             userDriver: ToastUpdateDriver(model: model, automatic: automatic), delegate: nil)
    }

    /// Starts the schedule of background checks. Call once the first window is up.
    func start() {
        guard let updater else { return }
        do { try updater.start() } catch { NSLog("Koi: updates are off: \(error.localizedDescription)"); return }
        if checkAtLaunch { updater.checkForUpdatesInBackground() }
    }

    /// The person asked: say so on the toast whatever the answer.
    func checkNow() {
        guard let updater else {
            model.show(.failed("Updates are off in this build."), userInitiated: true)
            Task { @MainActor [model] in try? await Task.sleep(for: .seconds(3)); model.hide() }
            return
        }
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
}

/// The toast: bottom right of the window in front, like Koi's other notices, but
/// it stays until the update is dealt with and carries the buttons.
struct UpdateToast: View {
    let model: UpdateToastModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                if case .downloading(_, let fraction) = model.phase {
                    if let fraction { ProgressView(value: fraction).frame(width: 180) }
                    else { ProgressView().progressViewStyle(.linear).frame(width: 180) }
                }
            }
            switch model.phase {
            case .available:
                Button("Later") { model.decline() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Update") { model.accept() }.buttonStyle(.borderedProminent).controlSize(.small)
            case .ready:
                Button("Later") { model.decline() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Restart") { model.accept() }.buttonStyle(.borderedProminent).controlSize(.small)
            case .checking, .downloading:
                Button("Cancel") { model.cancel() }.buttonStyle(.plain).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .modifier(FloatingSurface(cornerRadius: 18))
        .fixedSize()
    }

    private var title: String {
        switch model.phase {
        case .hidden: ""
        case .checking: "Checking for updates…"
        case .available(let version): "Koi \(version) is available"
        case .downloading(let version, _): "Downloading Koi \(version)…"
        case .extracting(let version): "Preparing Koi \(version)…"
        case .ready(let version): "Koi \(version) is ready"
        case .installing(let version): "Installing Koi \(version)…"
        case .upToDate: "Koi is up to date"
        case .failed(let message): message
        }
    }

    private var detail: String? {
        switch model.phase {
        case .ready: "Restart to finish. Your terminals keep running."
        case .available: "It downloads in the background."
        default: nil
        }
    }
}

/// Puts the toast in whichever Koi window is in front and keeps it there as
/// windows come and go; with no window open it waits.
@MainActor final class UpdateToastPresenter {
    private let model: UpdateToastModel
    private var host: NSHostingView<UpdateToast>?

    /// Lives as long as the app, so its observers are never removed.
    init(model: UpdateToastModel) {
        self.model = model
        for name in [NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
        observe()
    }

    /// Re-runs `sync` whenever the model's phase changes.
    private func observe() {
        withObservationTracking { _ = model.phase } onChange: { [weak self] in
            Task { @MainActor in self?.sync(); self?.observe() }
        }
    }

    private func sync() {
        guard model.phase != .hidden, let parent = Self.frontContentView() else {
            host?.removeFromSuperview()
            host = nil
            return
        }
        if let host, host.superview === parent { return }
        host?.removeFromSuperview()
        let view = NSHostingView(rootView: UpdateToast(model: model))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.safeAreaRegions = []
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -16),
        ])
        host = view
    }

    private static func frontContentView() -> NSView? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows
        return candidates.compactMap { $0 }.first { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }?.contentView
    }
}

/// Settings → Advanced. Whether this build updates itself is decided by the
/// build, not here; this only turns the background checks on or off.
struct UpdateSettingsView: View {
    let updater: AppUpdater
    @State private var automatic = false
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates").font(.headline)
            if updater.isConfigured {
                Toggle("Check for updates automatically", isOn: $automatic)
                    .onChange(of: automatic) { _, value in updater.automaticallyChecks = value }
                Text("Koi checks about once a day. An update downloads in the background, is verified against Koi's signing key, and installs when you restart. Nothing about this Mac is sent.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Check Now") { updater.checkNow() }
                    Text("Koi \(version)").foregroundStyle(.secondary)
                }
            } else {
                Text("This build of Koi doesn't update itself. Koi \(version).").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { automatic = updater.automaticallyChecks }
    }
}
