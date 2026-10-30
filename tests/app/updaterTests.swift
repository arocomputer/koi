import Foundation
import Sparkle
import Testing
@testable import Koi

/// The update toast's behavior, driven through the same callbacks Sparkle makes.
/// Sparkle itself (the download, the signature check, replacing the app) is its
/// own project's to test; what is Koi's is what the person sees and may choose.
@MainActor @Suite struct UpdaterTests {
    private func driver(model: UpdateToastModel = UpdateToastModel()) -> ToastUpdateDriver {
        let driver = ToastUpdateDriver(model: model)
        driver.noticeSeconds = 0.02
        driver.errorSeconds = 0.02
        return driver
    }

    @Test func anOfferIsAcceptedOrLeftForLaterAndAnsweredOnce() {
        let model = UpdateToastModel()
        let driver = driver(model: model)
        var choices: [SPUUserUpdateChoice] = []
        driver.offer(version: "0.2.0") { choices.append($0) }
        #expect(model.phase == .available(version: "0.2.0"))
        model.accept()
        model.accept()
        #expect(choices == [.install], "a second click does not answer twice")

        driver.offer(version: "0.3.0") { choices.append($0) }
        model.decline()
        #expect(choices == [.install, .dismiss])
        #expect(model.phase == .hidden, "Later clears the toast")
    }

    @Test func downloadProgressFollowsTheBytesAndAdmitsWhenTheTotalIsUnknown() {
        let model = UpdateToastModel()
        let driver = driver(model: model)
        driver.offer(version: "0.2.0") { _ in }
        driver.showDownloadInitiated {}
        driver.showDownloadDidReceiveData(ofLength: 10)
        #expect(model.phase == .downloading(version: "0.2.0", fraction: nil), "no total yet, so no fraction")
        driver.showDownloadDidReceiveExpectedContentLength(200)
        driver.showDownloadDidReceiveData(ofLength: 50)
        #expect(model.phase == .downloading(version: "0.2.0", fraction: 0.3))
        driver.showDownloadDidReceiveData(ofLength: 500)
        #expect(model.phase == .downloading(version: "0.2.0", fraction: 1), "never past full")
        driver.showDownloadDidStartExtractingUpdate()
        #expect(model.phase == .extracting(version: "0.2.0"))
        #expect(model.onCancel == nil, "extracting can no longer be cancelled")
    }

    @Test func aReadyUpdateRestartsNowOrInstallsWhenKoiQuits() {
        let model = UpdateToastModel()
        let driver = driver(model: model)
        var choices: [SPUUserUpdateChoice] = []
        driver.offer(version: "0.2.0") { _ in }
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(model.phase == .ready(version: "0.2.0"))
        model.decline()
        #expect(choices == [.dismiss])
        #expect(model.phase == .hidden)

        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        model.accept()
        #expect(choices == [.dismiss, .install])
    }

    @Test func aBackgroundCheckThatFindsNothingOrFailsSaysNothing() async {
        let model = UpdateToastModel()
        let driver = driver(model: model)
        var acknowledged = 0
        driver.showUpdateNotFoundWithError(CocoaError(.fileNoSuchFile)) { acknowledged += 1 }
        driver.showUpdaterError(URLError(.notConnectedToInternet)) { acknowledged += 1 }
        #expect(acknowledged == 2, "Sparkle is told at once")
        #expect(model.phase == .hidden)
    }

    @Test func aCheckThePersonAskedForAnswersEvenWhenThereIsNothingNew() async throws {
        let model = UpdateToastModel()
        let driver = driver(model: model)
        var acknowledged = false
        driver.showUserInitiatedUpdateCheck {}
        #expect(model.phase == .checking)
        driver.showUpdateNotFoundWithError(CocoaError(.fileNoSuchFile)) { acknowledged = true }
        #expect(model.phase == .upToDate)
        driver.dismissUpdateInstallation()
        #expect(model.phase == .upToDate, "the message stays for its moment")
        // The notice clears on a short timer; wait for that, generously, rather than a fixed moment.
        for _ in 0..<500 where model.phase != .hidden || !acknowledged { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.phase == .hidden)
        #expect(acknowledged)
    }

    @Test func cancellingACheckOrDownloadClearsTheToastAndTellsSparkle() {
        let model = UpdateToastModel()
        let driver = driver(model: model)
        var cancelled = 0
        driver.showUserInitiatedUpdateCheck { cancelled += 1 }
        model.cancel()
        #expect(cancelled == 1 && model.phase == .hidden)
        driver.offer(version: "0.2.0") { _ in }
        driver.showDownloadInitiated { cancelled += 1 }
        model.cancel()
        #expect(cancelled == 2 && model.phase == .hidden)
    }

    @Test func errorsAreSaidPlainly() {
        let offline = ToastUpdateDriver.message(for: URLError(.notConnectedToInternet))
        #expect(offline.contains("Couldn't reach the update server"))
        let other = ToastUpdateDriver.message(for: CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "no room"]))
        #expect(other == "The update didn't install: no room")
    }

    @Test func aBuildWithoutAFeedAndKeyNeverStartsAnUpdater() {
        // The test bundle carries neither, like Koid and any local build.
        let updater = AppUpdater(bundle: .main)
        #expect(!updater.isConfigured)
        updater.checkNow()
        #expect(updater.model.phase == .failed("Updates are off in this build."))
        #expect(!updater.automaticallyChecks)
    }
}
