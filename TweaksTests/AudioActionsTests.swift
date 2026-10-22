import AppKit
import XCTest
@testable import Tweaks

@MainActor
final class AudioActionsTests: XCTestCase {
    private var domain: String!
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        domain = "TweaksAudioActions-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        defaults.set([String](), forKey: TweakSettings.shareURLsKey)
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        pasteboard.releaseGlobally()
    }

    func testExistingPreferencesAndAudioRulesAreNotRewrittenByNewModels() throws {
        defaults.set(false, forKey: Tweak.wakeVolumeLimit.rawValue)
        defaults.set(true, forKey: Tweak.deviceVolumeLimits.rawValue)
        defaults.set(false, forKey: Tweak.cleanCopiedLinks.rawValue)
        let rules = ["UID": DeviceVolumeRule(name: "Headphones", maximum: 0.25, muteOnSwitchAway: true)]
        let bytes = try JSONEncoder().encode(rules)
        defaults.set(bytes, forKey: "deviceVolumeRules")
        defaults.set("untouched", forKey: "unrelatedSetting")
        let before = defaults.persistentDomain(forName: domain)! as NSDictionary
        let settings = TweakSettings(defaults: defaults)
        let limits = DeviceVolumeLimits(defaults: defaults)
        _ = LinkCleaner(defaults: defaults, pasteboard: pasteboard)
        _ = AutomationPause(defaults: defaults)
        XCTAssertFalse(settings.isOn(.wakeVolumeLimit))
        XCTAssertTrue(settings.isOn(.deviceVolumeLimits))
        XCTAssertFalse(settings.isOn(.cleanCopiedLinks))
        XCTAssertEqual(limits.rules, rules)
        XCTAssertEqual(limits.wakeMaximum, 0.4)
        XCTAssertEqual(defaults.data(forKey: "deviceVolumeRules"), bytes)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)! as NSDictionary, before)
    }

    func testAudioWakeLimitPreservesStricterLegacyCeilingAndPersistsOnlyExplicitEdits() {
        XCTAssertEqual(DeviceVolumeLimits.wakeLimit(defaultMaximum: 0.4, deviceMaximum: 0.8), 0.4)
        XCTAssertEqual(DeviceVolumeLimits.wakeLimit(defaultMaximum: 0.4, deviceMaximum: 0.2), 0.2)
        XCTAssertEqual(DeviceVolumeLimits.wakeLimit(defaultMaximum: 0.4, deviceMaximum: nil), 0.4)
        let limits = DeviceVolumeLimits(defaults: defaults)
        limits.setWakeMaximum(0.3)
        limits.setWakeMaximum(.nan)
        XCTAssertEqual(DeviceVolumeLimits(defaults: defaults).wakeMaximum, 0.3)
        XCTAssertNil(defaults.object(forKey: Tweak.deviceVolumeLimits.rawValue))
        XCTAssertNil(defaults.object(forKey: Tweak.wakeVolumeLimit.rawValue))
    }

    func testImmediateLinkCleaningRestoresAllOriginalPasteboardFormats() {
        let original = "https://example.com/watch?id=12&utm_source=email"
        let item = NSPasteboardItem()
        item.setString(original, forType: .string)
        item.setString(original, forType: .URL)
        pasteboard.writeObjects([item])
        let cleaner = LinkCleaner(defaults: defaults, pasteboard: pasteboard)
        var actions: [String] = []
        cleaner.onAction = { actions.append($0) }
        XCTAssertTrue(cleaner.cleanNow())
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/watch?id=12")
        XCTAssertTrue(cleaner.canRestore)
        XCTAssertTrue(cleaner.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), original)
        XCTAssertEqual(pasteboard.string(forType: .URL), original)
        XCTAssertFalse(cleaner.canRestore)
        XCTAssertEqual(actions.count, 2)
        XCTAssertFalse(actions.joined().contains("utm_source"))
    }

    func testRestoreNeverOverwritesANewerCopyEvenWhenItHasIdenticalText() {
        pasteboard.setString("https://example.com/?utm_source=x", forType: .string)
        let cleaner = LinkCleaner(defaults: defaults, pasteboard: pasteboard)
        XCTAssertTrue(cleaner.cleanNow())
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/", forType: .string)
        XCTAssertFalse(cleaner.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/")
    }

    func testConcurrentClipboardWriterCannotBeClaimedAsRestorableOriginal() {
        pasteboard.setString("https://example.com/?utm_source=x", forType: .string)
        let cleaner = LinkCleaner(defaults: defaults, pasteboard: pasteboard, writeItems: { board, items in
            let result = board.writeObjects(items)
            board.clearContents()
            board.setString("A newer copy", forType: .string)
            return result
        })
        XCTAssertFalse(cleaner.cleanNow())
        XCTAssertFalse(cleaner.canRestore)
        XCTAssertFalse(cleaner.restoreOriginal())
        XCTAssertEqual(pasteboard.string(forType: .string), "A newer copy")
    }

    func testClipboardOwnershipRefreshExpiresTheOriginalAndUpdatesStatus() {
        pasteboard.setString("https://example.com/?utm_source=x", forType: .string)
        let cleaner = LinkCleaner(defaults: defaults, pasteboard: pasteboard)
        XCTAssertTrue(cleaner.cleanNow())
        pasteboard.clearContents()
        pasteboard.setString("New text", forType: .string)
        cleaner.refreshClipboardState()
        XCTAssertFalse(cleaner.canRestore)
        XCTAssertTrue(cleaner.status.contains("clipboard changed"))
    }

    func testDMGSessionCannotResumeAfterPauseAndRestart() {
        var session = InstallerSession()
        let old = session.begin()
        XCTAssertTrue(session.accepts(old))
        session.end()
        XCTAssertFalse(session.accepts(old))
        let current = session.begin()
        XCTAssertFalse(session.accepts(old))
        XCTAssertTrue(session.accepts(current))
    }

    func testManualCleaningHonorsProtectedItemsAndSiteBoundaries() {
        let item = NSPasteboardItem()
        item.setString("https://example.com/?utm_source=x", forType: .string)
        item.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        let cleaner = LinkCleaner(defaults: defaults, pasteboard: pasteboard)
        let count = pasteboard.changeCount
        XCTAssertFalse(cleaner.cleanNow())
        XCTAssertEqual(pasteboard.changeCount, count)
        cleaner.setExcludedHosts("Example.com, example.com, other.example")
        XCTAssertTrue(cleaner.isExcluded("a.example.com"))
        XCTAssertFalse(cleaner.isExcluded("notexample.com"))
        pasteboard.clearContents()
        pasteboard.setString("https://a.example.com/?utm_source=x", forType: .string)
        XCTAssertFalse(cleaner.cleanNow())
        XCTAssertEqual(pasteboard.string(forType: .string), "https://a.example.com/?utm_source=x")
        XCTAssertEqual(LinkCleaner(defaults: defaults, pasteboard: pasteboard).excludedHosts, ["example.com", "other.example"])
    }

    func testPausePersistsDeadlineExpiresAndNeverChangesFeatureSwitches() {
        defaults.set(true, forKey: Tweak.unzipDownloads.rawValue)
        defaults.set(false, forKey: Tweak.dmgInstaller.rawValue)
        let pause = AutomationPause(defaults: defaults)
        let now = Date()
        pause.pause(for: 1800, now: now)
        XCTAssertTrue(AutomationPause(defaults: defaults, now: now).isPaused)
        pause.expireIfNeeded(now: now.addingTimeInterval(1799))
        XCTAssertTrue(pause.isPaused)
        pause.expireIfNeeded(now: now.addingTimeInterval(1800))
        XCTAssertFalse(pause.isPaused)
        XCTAssertTrue(defaults.bool(forKey: Tweak.unzipDownloads.rawValue))
        XCTAssertFalse(defaults.bool(forKey: Tweak.dmgInstaller.rawValue))
        XCTAssertNil(defaults.object(forKey: "fileAutomationPausedUntil"))
    }

    func testPauseGatesOnlyFileAndAutomaticClipboardWorkAndResumeUsesCurrentChoices() {
        // Restore an already active pause; no controller.start() or real background actions.
        defaults.set(Date().addingTimeInterval(1800), forKey: "fileAutomationPausedUntil")
        let controller = TweakController(defaults: defaults)
        let settings = TweakSettings(defaults: defaults)
        controller.settings = settings
        XCTAssertTrue(settings.isOn(.unzipDownloads))
        XCTAssertFalse(controller.shouldRun(.unzipDownloads))
        XCTAssertFalse(controller.shouldRun(.cleanCopiedLinks))
        XCTAssertTrue(controller.shouldRun(.autoConnectShares))
        XCTAssertTrue(controller.shouldRun(.awakeWhileRendering))
        XCTAssertNil(controller.shortcuts.shortcut(for: .cleanLink))
        // Avoid starting real features from the controller's resume callback.
        controller.automationPause.onChange = nil
        settings.set(.unzipDownloads, on: false)
        controller.automationPause.resume()
        XCTAssertFalse(controller.shouldRun(.unzipDownloads))
        XCTAssertTrue(controller.shouldRun(.cleanCopiedLinks))
    }

    func testCancelledDownloadSessionDoesNotProcessFilesArrivingDuringPause() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = DownloadsWatcher(folder: folder, fileIsOpen: { _ in false })
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        watcher.stop()
        let pausedArrival = folder.appending(path: "PAUSED.JPG")
        try Data("photo".utf8).write(to: pausedArrival)
        watcher.start()
        await watcher.waitUntilReady()
        await watcher.scan(now: Date().addingTimeInterval(10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pausedArrival.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains("PAUSED.JPG"))
        XCTAssertFalse(names.contains("PAUSED.jpg"))
        watcher.stop()
    }

    func testRecentActionsAreBoundedNewestFirstAndClearable() {
        let history = RecentActions()
        for index in 0..<120 { history.record("Action \(index)") }
        XCTAssertEqual(history.entries.count, 100)
        XCTAssertEqual(history.entries.first?.message, "Action 119")
        XCTAssertEqual(history.entries.last?.message, "Action 20")
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(RecentActions().entries.isEmpty)
    }

    func testDownloadRenameReportsAnActualCompletedAction() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = DownloadsWatcher(folder: folder, fileIsOpen: { _ in false })
        let logged = expectation(description: "Completed rename is reported")
        let history = RecentActions()
        watcher.onAction = { message in history.record(message); logged.fulfill() }
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        let source = folder.appending(path: "ACTION.JPG")
        try Data("image".utf8).write(to: source)
        let now = Date()
        await watcher.scan(now: now)
        await watcher.scan(now: now.addingTimeInterval(10))
        await fulfillment(of: [logged], timeout: 2)
        XCTAssertTrue(history.entries.first?.message.contains("ACTION.jpg") == true)
        XCTAssertFalse(history.entries.first?.message.contains(folder.path) == true)
        watcher.stop()
    }
}
