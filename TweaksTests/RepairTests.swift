import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Tweaks

@MainActor
final class RepairTests: XCTestCase {
    private var domain = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        domain = "TweaksRepair-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    func testLegacyShareArrayMigratesOnceAndEditingDoesNotEnableIt() {
        let urls = ["smb://example.invalid/projects"]
        defaults.set(urls, forKey: "autoConnectShares")
        let model = TweakSettings(defaults: defaults, mountedShares: { XCTFail("Must use saved list"); return [] })
        XCTAssertEqual(model.autoShares, urls)
        XCTAssertTrue(model.isOn(.autoConnectShares))
        model.set(.autoConnectShares, on: false)
        model.setAutoShares(urls + ["smb://example.invalid/archive"])
        for _ in 0..<3 {
            let reloaded = TweakSettings(defaults: defaults, mountedShares: { [] })
            XCTAssertFalse(reloaded.isOn(.autoConnectShares))
            XCTAssertEqual(reloaded.autoShares.count, 2)
        }
    }

    func testLegacyDisabledSwitchStaysDisabledWhileSeedingNewList() {
        defaults.set(false, forKey: "autoConnectShares")
        let model = TweakSettings(defaults: defaults, mountedShares: { ["smb://example.invalid/mounted"] })
        XCTAssertFalse(model.isOn(.autoConnectShares))
        XCTAssertEqual(model.autoShares.count, 1)
        XCTAssertFalse(TweakSettings(defaults: defaults, mountedShares: { [] }).isOn(.autoConnectShares))
    }

    func testExplicitShortcutWinsAgainstDefaultOnReload() throws {
        let original = ShortcutAction.keepAwake.defaultShortcut!
        let custom = Shortcut(keyCode: original.keyCode, modifiers: original.modifiers, key: "?")
        defaults.set(try JSONEncoder().encode(custom), forKey: "shortcut.screenOff")
        let store = ShortcutStore(defaults: defaults)
        XCTAssertNil(store.shortcut(for: .keepAwake))
        XCTAssertEqual(store.shortcut(for: .screenOff), custom)
        XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: .keepAwake))
    }

    func testCarbonRegistrationFailureIsReported() throws {
        let first = HotKey(keyCode: UInt32(kVK_F19), onPress: {})
        defer { first.unregister() }
        guard first.registrationStatus == noErr else { throw XCTSkip("F19 chord already registered by another app") }
        let duplicate = HotKey(keyCode: UInt32(kVK_F19), onPress: {})
        defer { duplicate.unregister() }
        XCTAssertNotEqual(duplicate.registrationStatus, noErr)
        XCTAssertNotNil(HotKey.failureMessage(status: duplicate.registrationStatus))
        XCTAssertNil(HotKey.failureMessage(status: first.registrationStatus))
    }

    func testCapsLockPreservesDifferentDeviceValuesAndScopesThemToBoot() {
        let table = "RegistryID Key Value\n100000b57 CapsLockDelayOverride 100000000\n100000b58 CapsLockDelayOverride 80000000\n100000b59 CapsLockDelayOverride (null)"
        XCTAssertEqual(CapsLockDelay.table(hidutilOutput: table), ["100000b57": 100_000_000, "100000b58": 80_000_000])
        XCTAssertNil(CapsLockDelay.parse(hidutilOutput: table), "Mixed delays cannot be restored as one scalar")
        CapsLockTweak.saveOriginals(["a": 100_000_000, "b": 80_000_000], boot: "boot1", defaults: defaults)
        CapsLockTweak.saveOriginals(["a": 0, "b": 0, "c": 50_000_000], boot: "boot1", defaults: defaults)
        XCTAssertEqual(CapsLockTweak.originals(boot: "boot1", defaults: defaults), ["a": 100_000_000, "b": 80_000_000, "c": 50_000_000])
        XCTAssertTrue(CapsLockTweak.originals(boot: "boot2", defaults: defaults).isEmpty)
    }

    func testChannelOnlyVolumeDiscoveryAndCapDoNotRaiseQuieterChannels() {
        let elements = AudioVolumeChannels.elements(channelCount: 4, writable: { $0 == 1 || $0 == 2 || $0 == 4 })
        XCTAssertEqual(elements, [1, 2, 4])
        var values: [UInt32: Float] = [1: 0.2, 2: 0.9, 4: 0.7]
        XCTAssertEqual(AudioVolumeChannels.maximum(elements: elements, read: { values[$0] }), 0.9)
        XCTAssertTrue(AudioVolumeChannels.cap(0.4, elements: elements, read: { values[$0] }, write: { values[$0] = $1; return true }))
        XCTAssertEqual(values, [1: 0.2, 2: 0.4, 4: 0.4])
        XCTAssertEqual(AudioVolumeChannels.elements(channelCount: 4, writable: { _ in true }), [0])
    }

    func testCapsLockRecapturesAfterDisableAndRetainsFailedRestores() {
        CapsLockTweak.apply(current: ["a": 100_000_000, "b": 80_000_000], boot: "boot", defaults: defaults, write: { _, _ in true })
        CapsLockTweak.restore(ids: ["a", "b"], boot: "boot", defaults: defaults, write: { id, _ in id == "a" })
        XCTAssertEqual(CapsLockTweak.originals(boot: "boot", defaults: defaults), ["b": 80_000_000])
        CapsLockTweak.apply(current: ["a": 200_000_000, "b": 0], boot: "boot", defaults: defaults, write: { _, _ in true })
        var restored: [String: Int] = [:]
        CapsLockTweak.restore(ids: ["a", "b"], boot: "boot", defaults: defaults, write: { restored[$0] = $1; return true })
        XCTAssertEqual(restored, ["a": 200_000_000, "b": 80_000_000])
    }

    func testChannelReadAndWriteFailuresAreNotSuccess() {
        XCTAssertNil(AudioVolumeChannels.maximum(elements: [1, 2], read: { $0 == 1 ? 0.8 : nil }))
        XCTAssertFalse(AudioVolumeChannels.cap(0.4, elements: [1, 2], read: { _ in 0.8 }, write: { element, _ in element == 1 }))
        XCTAssertFalse(AudioVolumeChannels.cap(0.4, elements: [], read: { _ in nil }, write: { _, _ in true }))
    }

    func testRoundedFirstChannelDoesNotHideAnIncreaseOnAnotherChannel() {
        var enforcer = ChannelVolumeLimitEnforcer()
        var values: [UInt32: Float] = [1: 0.8, 2: 0.2]
        let write: (Float) -> Bool = { _ in
            values[1] = 0.5 // hardware cannot reach the requested 0.4
            values[2] = min(values[2]!, 0.4)
            return true
        }
        XCTAssertEqual(enforcer.enforce(maximum: 0.4, read: { values }, write: write), .rounded(0.5))
        XCTAssertNil(enforcer.enforce(maximum: 0.4, read: { values }, write: write))
        values[2] = 0.45 // the maximum is unchanged, but this channel needs a cap
        XCTAssertNotNil(enforcer.enforce(maximum: 0.4, read: { values }, write: write))
        XCTAssertEqual(values[2], 0.4)
    }

    func testAudioSuppressionStoresOnlyEvaluatedReadbacks() {
        var enforcer = ChannelVolumeLimitEnforcer()
        var reads = 0
        let read: () -> [UInt32: Float]? = {
            reads += 1
            // Initial read plus three bounded correction readbacks. A later
            // change must be evaluated on the next notification, not cached.
            return [1: 0.5, 2: reads <= 4 ? 0.2 : 0.45]
        }
        XCTAssertEqual(enforcer.enforce(maximum: 0.4, read: read, write: { _ in true }), .rounded(0.5))
        XCTAssertEqual(reads, 4)
        XCTAssertNotNil(enforcer.enforce(maximum: 0.4, read: read, write: { _ in true }))
    }

    func testShareRecoverySurvivesSleepAndRestart() {
        let a = URL(string: "smb://example.invalid/a")!
        let b = URL(string: "smb://example.invalid/b")!
        let queue = ShareRemountQueue(defaults: defaults, mounted: { [] }, reachable: { _ in false }, mount: { _ in false }, watchConnectivity: false)
        queue.enqueue([a])
        queue.resume()
        queue.suspend()
        queue.enqueue([b])
        XCTAssertEqual(queue.pending, [a, b])
        let reloaded = ShareRemountQueue(defaults: defaults, watchConnectivity: false)
        XCTAssertEqual(reloaded.pending, [a, b])
        queue.suspend()
        reloaded.suspend()
    }

    func testShareRecoveryRetriesBeyondTwelveAttemptsUntilSuccess() async {
        let restored = expectation(description: "server eventually reachable")
        var attempts = 0
        var delays: [TimeInterval] = []
        let queue = ShareRemountQueue(defaults: defaults, mounted: { [] }, reachable: { _ in
            attempts += 1
            return attempts == 15
        }, mount: { _ in restored.fulfill(); return true }, wait: { delay in
            delays.append(delay)
            await Task.yield()
            try Task.checkCancellation()
        }, watchConnectivity: false)
        defer { queue.suspend() }
        queue.enqueue([URL(string: "smb://example.invalid/a")!])
        queue.resume()
        await fulfillment(of: [restored], timeout: 3)
        await Task.yield()
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(attempts, 15)
        XCTAssertTrue(delays.contains(60))
        XCTAssertEqual(defaults.stringArray(forKey: ShareRemountQueue.key), [])
    }

    func testCancelledMountCannotForgetShareDuringAnotherSleep() async {
        let entered = expectation(description: "mount entered")
        var finish: CheckedContinuation<Bool, Never>?
        let url = URL(string: "smb://example.invalid/a")!
        let queue = ShareRemountQueue(defaults: defaults, mounted: { [] }, reachable: { _ in true }, mount: { _ in
            await withCheckedContinuation { continuation in finish = continuation; entered.fulfill() }
        }, wait: { _ in await Task.yield() }, watchConnectivity: false)
        queue.enqueue([url]); queue.resume()
        await fulfillment(of: [entered], timeout: 3)
        queue.suspend()
        queue.enqueue([url])
        finish?.resume(returning: true)
        await Task.yield()
        XCTAssertEqual(queue.pending, [url])
    }

    func testLateUnmountAfterWakeCannotBeMistakenForRestore() async {
        let checked = expectation(description: "checked while unmount pending")
        let restored = expectation(description: "restored after late unmount")
        let url = URL(string: "smb://example.invalid/a")!
        var mounted = true
        var checks = 0
        let queue = ShareRemountQueue(defaults: defaults, mounted: { [url].filter { _ in mounted } },
            reachable: { _ in true }, mount: { _ in restored.fulfill(); return true }, wait: { _ in
                checks += 1
                if checks == 2 {
                    checked.fulfill()
                    try await Task.sleep(for: .seconds(60))
                }
                await Task.yield()
                try Task.checkCancellation()
            }, watchConnectivity: false)
        defer { queue.suspend() }
        queue.enqueue([url]); queue.beginUnmount(url); queue.resume()
        await fulfillment(of: [checked], timeout: 3)
        XCTAssertEqual(queue.pending, [url])
        mounted = false
        queue.endUnmount(url)
        await fulfillment(of: [restored], timeout: 3)
        await Task.yield()
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testDMGPathRejectsTraversalAndEscapingSymlink() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = folder.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: downloads.appending(path: "outside"), withDestinationURL: folder)
        XCTAssertTrue(DMGInstaller.isInside(downloads.appending(path: "nested/App.dmg"), directory: downloads))
        XCTAssertFalse(DMGInstaller.isInside(downloads.appending(path: "../App.dmg"), directory: downloads))
        XCTAssertFalse(DMGInstaller.isInside(downloads.appending(path: "outside/App.dmg"), directory: downloads))
    }

    func testAppUpdatePreservesOldCopyForTrash() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "Example.app")
        let staged = folder.appending(path: ".staged.app")
        try appFixture(old, contents: "old")
        try appFixture(staged, contents: "new")
        let trash = folder.appending(path: "Trash.app")
        let note = try DMGInstaller.replaceApp(at: old, with: staged, trash: { try FileManager.default.moveItem(at: $0, to: trash) })
        XCTAssertNil(note)
        XCTAssertEqual(try String(contentsOf: old.appending(path: "version"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: trash.appending(path: "version"), encoding: .utf8), "old")
    }

    func testFailedBackupTrashKeepsRecoverableApp() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "Example.app"), staged = folder.appending(path: ".staged.app")
        try appFixture(old, contents: "old"); try appFixture(staged, contents: "new")
        var backup: URL?
        let note = try DMGInstaller.replaceApp(at: old, with: staged, trash: { backup = $0; throw CocoaError(.fileWriteNoPermission) })
        XCTAssertNotNil(note)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backup).appending(path: "version"), encoding: .utf8), "old")
    }

    func testFailedEjectKeepsImageAndReportsIt() async {
        var trashed = false
        let note = await DMGInstaller.finishImage(URL(filePath: "/tmp/example.dmg"), detach: { false }, trash: { _ in trashed = true })
        XCTAssertNotNil(note)
        XCTAssertFalse(trashed)
    }

    func testArchiveUtilityDefersInsteadOfForgettingArrival() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appending(path: "Example.zip")
        try Data("untouched archive".utf8).write(to: archive)
        let deferred = expectation(description: "download retried")
        await DownloadsWatcher.unzip(archive, archiveUtilityRunning: { true }, onDeferred: { deferred.fulfill() })
        await fulfillment(of: [deferred], timeout: 1)
        XCTAssertEqual(try Data(contentsOf: archive), Data("untouched archive".utf8))
    }

    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TweaksRepair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func appFixture(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url.appending(path: "version"))
    }
}
