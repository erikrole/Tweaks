import AppKit
import XCTest
@testable import Tweaks

private final class StatusCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class StatusControlsTests: XCTestCase {
    private var domain: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        domain = "TweaksStatusControls-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        defaults.set([String](), forKey: TweakSettings.shareURLsKey)
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    func testStatusSeparatesIntentPausePermissionAndObservedActivity() {
        let active = FeatureRuntime(phase: .active, message: "Rendering")
        XCTAssertEqual(FeatureRuntime.resolve(enabled: false, runtime: active).phase, .off)
        XCTAssertEqual(FeatureRuntime.resolve(enabled: true, pausedUntil: Date(), runtime: active).phase, .paused)
        XCTAssertEqual(FeatureRuntime.resolve(enabled: true, needsAccess: true, hasAccess: false, runtime: active).phase, .blocked)
        XCTAssertEqual(FeatureRuntime.resolve(enabled: true, runtime: active), active)
    }

    func testPendingRecoveryRemainsVisibleWithSavedSwitchOff() {
        let recovery = FeatureRuntime(phase: .waiting, message: "Share restore pending", finishingRecovery: true)
        XCTAssertEqual(FeatureRuntime.resolve(enabled: false, runtime: recovery), recovery)
        XCTAssertEqual(FeatureRuntime.resolve(enabled: false, runtime: .init(phase: .ready, message: "Restored")).phase, .off)
    }

    func testChosenAppSessionEndsWhenPIDIsReused() {
        let launched = Date().addingTimeInterval(-100)
        let until = KeepAwake.Until.appQuits(pid: 42, name: "Selected", launched: launched)
        XCTAssertNil(KeepAwake.endReason(for: until, now: Date(), isRunning: { _ in true }, battery: nil, launchDate: { _ in launched }))
        XCTAssertNotNil(KeepAwake.endReason(for: until, now: Date(), isRunning: { _ in true }, battery: nil, launchDate: { _ in launched.addingTimeInterval(10) }))
        XCTAssertNotNil(KeepAwake.endReason(for: until, now: Date(), isRunning: { _ in false }, battery: nil))
    }

    func testAudioFailuresCannotBePresentedAsReady() {
        XCTAssertEqual(VolumeLimitEnforcer.Result.failed.phase, .blocked)
        XCTAssertEqual(VolumeLimitEnforcer.Result.unverified.phase, .blocked)
        XCTAssertEqual(VolumeLimitEnforcer.Result.rounded(0.8).phase, .blocked)
        XCTAssertEqual(VolumeLimitEnforcer.Result.applied(0.4).phase, .ready)
        var enforcer = ChannelVolumeLimitEnforcer()
        _ = enforcer.enforce(maximum: 0.4, read: { [0: 0.8] }, write: { _ in false })
        XCTAssertFalse(enforcer.verifiedWithinLimit)
        XCTAssertNil(enforcer.enforce(maximum: 0.4, read: { [0: 0.2, 1: 0.3] }, write: { _ in XCTFail("Quiet channels must not be written"); return false }))
        XCTAssertTrue(enforcer.verifiedWithinLimit)
    }

    func testVisibleClockRefreshDoesNotDependOnMenuBarCountdownPreference() {
        defaults.set(false, forKey: "keepAwakeCountdown")
        let before = defaults.persistentDomain(forName: domain)! as NSDictionary
        let awake = KeepAwake(defaults: defaults)
        XCTAssertFalse(awake.showsCountdown)
        let nextMinute = awake.clockNow.addingTimeInterval(65)
        awake.refreshClock(now: nextMinute)
        XCTAssertEqual(awake.clockNow, nextMinute)
        XCTAssertNil(awake.session)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)! as NSDictionary, before)
    }

    func testDurationChoicesResolveFromStartTimeWithoutChangingDefaults() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (choice, seconds) in [(SessionEndChoice.halfHour, 1800.0), (.oneHour, 3600), (.twoHours, 7200), (.fourHours, 14400)] {
            XCTAssertEqual(choice.resolve(now: now, date: .distantPast, app: nil), .date(now.addingTimeInterval(seconds)))
        }
        XCTAssertEqual(SessionEndChoice.indefinitely.resolve(now: now, date: .distantPast, app: nil), .indefinitely)
        XCTAssertNil(SessionEndChoice.time.resolve(now: now, date: now, app: nil))
        XCTAssertNil(SessionEndChoice.time.resolve(now: now, date: Date(timeIntervalSinceReferenceDate: .infinity), app: nil))
        XCTAssertEqual(SessionEndChoice.time.resolve(now: now, date: now.addingTimeInterval(1234), app: nil), .date(now.addingTimeInterval(1234)))
        XCTAssertNil(SessionEndChoice.appQuits.resolve(now: now, date: now, app: nil))
        let app = SessionApp(pid: 42, name: "Test App", launched: now)
        XCTAssertEqual(SessionEndChoice.appQuits.resolve(now: now, date: now, app: app), .appQuits(pid: 42, name: "Test App", launched: now))
    }

    func testCustomPauseRejectsInvalidDatesAndPreservesAllOtherPreferences() {
        defaults.set(false, forKey: "cleanCopiedLinks")
        defaults.set(Data([1, 2, 3]), forKey: "shortcut.keepAwake")
        let before = defaults.persistentDomain(forName: domain)!
        let pause = AutomationPause(defaults: defaults)
        let now = Date()
        for seconds in [900.0, 1800, 3600] {
            XCTAssertTrue(pause.pause(until: now.addingTimeInterval(seconds), now: now))
            XCTAssertEqual(pause.until, now.addingTimeInterval(seconds))
        }
        XCTAssertFalse(pause.pause(until: now, now: now))
        XCTAssertFalse(pause.pause(until: Date(timeIntervalSinceReferenceDate: .infinity), now: now))
        XCTAssertEqual(pause.until, now.addingTimeInterval(3600))
        pause.resume()
        XCTAssertEqual(defaults.persistentDomain(forName: domain)! as NSDictionary, before as NSDictionary)
    }

    func testNewShortcutIsUnassignedAndExistingAssignmentsStayByteIdentical() throws {
        let stored = try JSONEncoder().encode(Shortcut(keyCode: 10, modifiers: Shortcut.hyperModifiers, key: "X"))
        defaults.set(stored, forKey: "shortcut.keepAwake")
        defaults.set(Data(), forKey: "shortcut.clearNotifications")
        let before = defaults.persistentDomain(forName: domain)! as NSDictionary
        let store = ShortcutStore(defaults: defaults)
        XCTAssertNil(store.shortcut(for: .toggleAutomationPause))
        XCTAssertNil(store.shortcut(for: .clearNotifications))
        XCTAssertEqual(defaults.data(forKey: "shortcut.keepAwake"), stored)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)! as NSDictionary, before)
    }

    func testStatusNavigationDoesNotActivateFeaturesOrWriteSettings() {
        defaults.set(false, forKey: Tweak.unzipDownloads.rawValue)
        let settings = TweakSettings(defaults: defaults)
        let controller = TweakController(defaults: defaults); controller.settings = settings
        let before = defaults.persistentDomain(forName: domain)! as NSDictionary
        let window = SettingsWindowController(settings: settings, tweaks: controller, launchAtLogin: LaunchAtLoginController())
        defer { window.close() }
        for pane in SettingsTab.allCases { window.selectPane(pane); window.sync() }
        XCTAssertEqual(window.activityStatusLabels.count, Tweak.allCases.count)
        XCTAssertEqual(controller.featureStatus(for: .unzipDownloads).phase, .off)
        XCTAssertEqual(controller.featureStatus(for: .autoConnectShares).phase, .waiting)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)! as NSDictionary, before)
        XCTAssertNil(controller.keepAwake.session)
    }

    func testExpandedSessionControlsScheduleDocumentMeasurement() async throws {
        let settings = TweakSettings(defaults: defaults)
        let controller = TweakController(defaults: defaults); controller.settings = settings
        let window = SettingsWindowController(settings: settings, tweaks: controller, launchAtLogin: LaunchAtLoginController())
        defer { window.close() }
        window.showWindow(nil); window.selectPane(.sleep)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try XCTUnwrap(descendants(window.window!.contentView!).compactMap { $0 as? NSScrollView }.first { $0.identifier?.rawValue == "settings-content" })
        let page = try XCTUnwrap(scroll.documentView as? SettingsPage)
        let original = page.frame.height
        window.awakeEnd.choice.selectItem(at: SessionEndChoice.time.rawValue)
        window.awakeEnd.changed()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThan(page.frame.height, original)
        XCTAssertGreaterThanOrEqual(page.frame.height + 0.5, page.column.fittingSize.height)
    }

    func testRoutineProgressAndRepeatedFailuresDoNotFloodHistory() {
        let controller = TweakController(defaults: defaults)
        controller.settings = TweakSettings(defaults: defaults)
        let waiting = FeatureRuntime(phase: .waiting, message: "Share server unavailable")
        for _ in 0..<20 {
            controller.updateRuntime(.autoConnectShares, status: .init(phase: .working, message: "Checking"))
            controller.updateRuntime(.autoConnectShares, status: waiting)
        }
        XCTAssertEqual(controller.recentActions.entries.count, 1)
        controller.updateRuntime(.autoConnectShares, status: .init(phase: .ready, message: "Connected"))
        controller.updateRuntime(.autoConnectShares, status: waiting)
        XCTAssertEqual(controller.recentActions.entries.count, 3)
        controller.settings?.set(.autoConnectShares, on: false)
        controller.updateRuntime(.autoConnectShares, status: .init(phase: .ready, message: "Old result"))
        XCTAssertEqual(controller.recentActions.entries.count, 3)
    }

    func testLateReachabilityFailureCannotOverwriteRestartedStatus() async throws {
        var continuation: CheckedContinuation<Bool, Never>?
        var states: [FeatureRuntime] = []
        var mounted = false
        let url = URL(string: "smb://fixture.invalid/share")!
        let connector = ShareAutoConnect(mounted: { mounted ? [url] : [] }, reachable: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, mount: { _ in XCTFail("No real mount"); return false }, wait: { _ in }, watchConnectivity: false)
        connector.shares = [url]; connector.onStatus = { states.append($0) }; connector.start()
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(continuation)
        connector.stop(); mounted = true; connector.start()
        try await Task.sleep(for: .milliseconds(20))
        continuation?.resume(returning: false)
        try await Task.sleep(for: .milliseconds(20))
        connector.stop()
        XCTAssertEqual(states.last?.phase, .ready)
        XCTAssertFalse(states.contains { $0.phase == .waiting })
    }

    func testEthernetStatusCannotBeRestampedOrSuppressedAcrossGenerations() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let worker = EthernetHandoffWorker(directory: directory, commandRunner: { _, _, _ in
            XCTFail("Status verification must not change the network"); return .init(status: -1, text: "")
        })
        defer { worker.queue.sync {}; try? FileManager.default.removeItem(at: directory) }
        let calls = StatusCount()
        worker.onStatus = { _, _ in calls.record() }
        worker.publish(.ready, "Same status", session: 0)
        worker.stop()
        worker.publish(.ready, "Old proof", session: 0)
        worker.publish(.ready, "Same status", session: 1)
        XCTAssertEqual(calls.value, 2)
        XCTAssertFalse(worker.acceptsStatus(0))
        XCTAssertTrue(worker.acceptsStatus(1))
    }

    func testOldSleepRestoreFailureCannotOverwriteNewRecoveryStatus() async throws {
        let url = URL(string: "smb://fixture.invalid/share")!
        defaults.set([url.absoluteString], forKey: ShareRemountQueue.key)
        var continuation: CheckedContinuation<Bool, Never>?
        var mounted = false, states: [FeatureRuntime] = []
        let queue = ShareRemountQueue(defaults: defaults, mounted: { mounted ? [url] : [] }, reachable: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, mount: { _ in XCTFail("No real mounts"); return false },
                                     wait: { _ in try await Task.sleep(for: .milliseconds(5)) }, watchConnectivity: false)
        queue.onStatus = { states.append($0) }; queue.resume()
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(continuation)
        queue.suspend(); mounted = true; queue.resume()
        try await Task.sleep(for: .milliseconds(20))
        let count = states.count
        continuation?.resume(returning: false)
        try await Task.sleep(for: .milliseconds(20))
        queue.suspend()
        XCTAssertEqual(states.count, count)
        XCTAssertEqual(states.last?.phase, .ready)
    }

    func testShareStatusReportsUnavailableAndConnectedWithoutRealMounts() async throws {
        var states: [FeatureRuntime] = [], checks = 0
        let url = URL(string: "smb://fixture.invalid/share")!
        let connector = ShareAutoConnect(mounted: { checks > 1 ? [url] : [] }, reachable: { _ in false },
                                         mount: { _ in XCTFail("An unavailable server must not be mounted"); return false },
                                         wait: { _ in checks += 1 }, watchConnectivity: false)
        connector.onStatus = { states.append($0) }; connector.shares = [url]
        connector.start()
        try await Task.sleep(for: .milliseconds(30))
        connector.stop()
        XCTAssertEqual(states.last?.phase, .ready)
        XCTAssertTrue(states.contains { $0.phase == .waiting })
    }
}
