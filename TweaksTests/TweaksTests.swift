import XCTest
@testable import Tweaks

@MainActor
final class DownloadsTests: XCTestCase {
    func testRemovesAlarmsOnly() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Practice
        BEGIN:VALARM
        TRIGGER:-PT15M
        ACTION:DISPLAY
        END:VALARM
        DTSTART:20261012T150000Z
        END:VEVENT
        END:VCALENDAR
        """
        let cleaned = DownloadsWatcher.removingAlarms(from: ics)
        XCTAssertFalse(cleaned.contains("VALARM"))
        XCTAssertFalse(cleaned.contains("TRIGGER"))
        XCTAssertTrue(cleaned.contains("SUMMARY:Practice"))
        XCTAssertTrue(cleaned.contains("DTSTART:20261012T150000Z"))
    }

    func testCRLFInvites() {
        let ics = "BEGIN:VEVENT\r\nBEGIN:VALARM\r\nTRIGGER:-PT5M\r\nEND:VALARM\r\nSUMMARY:A\r\nEND:VEVENT"
        let cleaned = DownloadsWatcher.removingAlarms(from: ics)
        XCTAssertFalse(cleaned.contains("TRIGGER"))
        XCTAssertTrue(cleaned.contains("SUMMARY:A"))
    }

    func testLowercaseExtensions() {
        XCTAssertEqual(DownloadsWatcher.lowercasedExtension(of: URL(filePath: "/tmp/IMG_0001.JPG"))?.lastPathComponent, "IMG_0001.jpg")
        XCTAssertNil(DownloadsWatcher.lowercasedExtension(of: URL(filePath: "/tmp/photo.jpg")))
        XCTAssertNil(DownloadsWatcher.lowercasedExtension(of: URL(filePath: "/tmp/README")))
    }

    func testInProgressDownloadsAreSkipped() {
        XCTAssertFalse(DownloadsWatcher.isFinishedDownload(URL(filePath: "/tmp/big.mov.crdownload")))
        XCTAssertFalse(DownloadsWatcher.isFinishedDownload(URL(filePath: "/tmp/big.mov.download")))
        XCTAssertTrue(DownloadsWatcher.isFinishedDownload(URL(filePath: "/tmp/big.mov")))
    }

    func testCaseOnlyRenameOnRealDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Clip.MOV")
        try Data("x".utf8).write(to: source)
        let target = try XCTUnwrap(DownloadsWatcher.lowercasedExtension(of: source))
        XCTAssertTrue(DownloadsWatcher.moveCaseOnly(from: source, to: target))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Clip.mov"])
    }
}

@MainActor
final class SystemTweakTests: XCTestCase {
    func testWakeVolumeOnlyLowers() {
        XCTAssertEqual(WakeVolume.target(current: 0.9), 0.4)
        XCTAssertNil(WakeVolume.target(current: 0.3))
        XCTAssertNil(WakeVolume.target(current: 0.4))
    }

    func testMusicBlockWindow() {
        let key = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(MusicLaunchBlocker.shouldBlock(launchAt: key.addingTimeInterval(1), lastPlayKey: key))
        XCTAssertFalse(MusicLaunchBlocker.shouldBlock(launchAt: key.addingTimeInterval(10), lastPlayKey: key))
        XCTAssertFalse(MusicLaunchBlocker.shouldBlock(launchAt: key, lastPlayKey: nil))
    }

    func testDMGImagePathOnlyFromDownloads() {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/App.dmg").path
        let info: [String: Any] = ["images": [
            ["image-path": downloads, "system-entities": [["mount-point": "/Volumes/App"]]],
            ["image-path": "/private/var/installer.dmg", "system-entities": [["mount-point": "/Volumes/Installer"]]],
        ]]
        XCTAssertEqual(DMGInstaller.imagePath(for: "/Volumes/App/", inHdiutilInfo: info)?.path, downloads)
        XCTAssertNil(DMGInstaller.imagePath(for: "/Volumes/Installer", inHdiutilInfo: info))
        XCTAssertNil(DMGInstaller.imagePath(for: "/Volumes/Other", inHdiutilInfo: info))
    }
}

@MainActor
final class AccessibilityTweakTests: XCTestCase {
    func testCloseActionPrefersClearAll() {
        let banner = ["AXPress", "Name:Show Details\nTarget:0x0", "Name:Close\nTarget:0x0\nSelector:(null)"]
        XCTAssertEqual(NotificationCloser.closeAction(in: banner), "Name:Close\nTarget:0x0\nSelector:(null)")
        let stack = ["Name:Close\nTarget:0x0", "Name:Clear All\nTarget:0x0"]
        XCTAssertEqual(NotificationCloser.closeAction(in: stack), "Name:Clear All\nTarget:0x0")
        XCTAssertNil(NotificationCloser.closeAction(in: ["AXPress"]))
    }

    func testShortcutBannerMatching() {
        XCTAssertTrue(NotificationCloser.isShortcutRunning("Shortcuts, Morning Routine, Running…"))
        XCTAssertFalse(NotificationCloser.isShortcutRunning("Shortcuts, Morning Routine, Done"))
        XCTAssertFalse(NotificationCloser.isShortcutRunning("Messages, Katie, running late"))
    }

    func testScreenGeometry() {
        // A 1440x900 visible frame starting 25 pt below the top of a 1440x925 primary screen.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(GreenButtonFill.convertToAX(visible, primaryHeight: 925), CGRect(x: 0, y: 25, width: 1440, height: 900))
        XCTAssertTrue(GreenButtonFill.approximatelyEqual(CGRect(x: 0, y: 25, width: 1440, height: 900), CGRect(x: 2, y: 27, width: 1436, height: 898)))
        XCTAssertFalse(GreenButtonFill.approximatelyEqual(CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 0, y: 25, width: 1440, height: 900)))
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsOnAndPersist() {
        let defaults = UserDefaults(suiteName: "TweaksTests-\(UUID().uuidString)")!
        let settings = TweakSettings(defaults: defaults)
        XCTAssertTrue(Tweak.allCases.filter { !Tweak.offByDefault.contains($0) }.allSatisfy(settings.isOn))
        XCTAssertFalse(settings.isOn(.wifiOffWhenWired))
        XCTAssertFalse(settings.isOn(.bluetoothOffWhileAsleep))
        var changed: [Tweak] = []
        settings.onChange = { changed.append($0) }
        settings.set(.dmgInstaller, on: false)
        settings.set(.dmgInstaller, on: false)
        XCTAssertEqual(changed, [.dmgInstaller], "no change event when nothing changed")
        XCTAssertFalse(TweakSettings(defaults: defaults).isOn(.dmgInstaller))
    }
}

@MainActor
final class WatcherIntegrationTests: XCTestCase {
    func testWatcherLowercasesNewDownloads() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appending(path: "Existing.PNG"))

        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        defer { watcher.stop() }
        try Data("new".utf8).write(to: folder.appending(path: "Photo.JPG"))

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if FileManager.default.fileExists(atPath: folder.appending(path: "Photo.jpg").path),
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains("Photo.jpg") == true { break }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["Existing.PNG", "Photo.jpg"], "new file renamed, existing file left alone")
    }
}

@MainActor
final class MoreTweakTests: XCTestCase {
    func testLinkCleaning() {
        XCTAssertEqual(LinkCleaner.clean("https://example.com/post?id=7&utm_source=x&utm_medium=email&fbclid=abc"),
                       "https://example.com/post?id=7")
        XCTAssertEqual(LinkCleaner.clean("https://www.youtube.com/watch?v=abc&si=TRACK&t=42"),
                       "https://www.youtube.com/watch?v=abc&t=42")
        XCTAssertEqual(LinkCleaner.clean("https://youtu.be/abc?si=TRACK"), "https://youtu.be/abc")
        XCTAssertEqual(LinkCleaner.clean("https://x.com/user/status/1?s=20&t=abc"), "https://x.com/user/status/1")
        XCTAssertEqual(LinkCleaner.clean("https://open.spotify.com/track/1?si=abc"), "https://open.spotify.com/track/1")
        // Untouched: clean links, non-links, other sites' meaningful params, text with spaces.
        XCTAssertEqual(LinkCleaner.clean("https://example.com/?q=search"), "https://example.com/?q=search")
        XCTAssertEqual(LinkCleaner.clean("https://github.com/x/y?feature=1"), "https://github.com/x/y?feature=1")
        XCTAssertNil(LinkCleaner.clean("check https://example.com?utm_source=x"))
        XCTAssertNil(LinkCleaner.clean("not a link"))
        XCTAssertNil(LinkCleaner.clean("ftp://example.com?utm_source=x"))
    }

    func testRenderDetection() {
        let ae = "/Applications/Adobe After Effects 2026/Adobe After Effects 2026.app/Contents/MacOS/After Effects"
        let aerender = "/Applications/Adobe After Effects 2026/aerender"
        XCTAssertEqual(RenderKeepAwake.busyRenderer(in: [ae: 340]), "After Effects")
        XCTAssertEqual(RenderKeepAwake.busyRenderer(in: [aerender: 120]), "aerender")
        XCTAssertNil(RenderKeepAwake.busyRenderer(in: [ae: 20]), "idle AE doesn't hold the Mac awake")
        XCTAssertNil(RenderKeepAwake.busyRenderer(in: ["/Applications/Dia.app/Contents/MacOS/Dia": 400]))
    }

    func testWhichDrivesEject() {
        XCTAssertTrue(SleepEjector.shouldEject(isLocal: true, isRoot: false, isInternal: false, isEjectable: true, isRemovable: false))
        XCTAssertFalse(SleepEjector.shouldEject(isLocal: true, isRoot: true, isInternal: true, isEjectable: false, isRemovable: false))
        XCTAssertFalse(SleepEjector.shouldEject(isLocal: false, isRoot: false, isInternal: false, isEjectable: true, isRemovable: false), "network shares stay")
        XCTAssertFalse(SleepEjector.shouldEject(isLocal: true, isRoot: false, isInternal: true, isEjectable: false, isRemovable: false))
    }

    func testQuitOnlyAfterHavingWindows() {
        XCTAssertTrue(LastWindowQuitter.shouldQuit(hadWindows: true, windowCount: 0))
        XCTAssertFalse(LastWindowQuitter.shouldQuit(hadWindows: false, windowCount: 0), "just launched, no window yet")
        XCTAssertFalse(LastWindowQuitter.shouldQuit(hadWindows: true, windowCount: 1))
    }

    func testUnzipSingleAndMultiple() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unzip-\(UUID().uuidString)")
        let source = folder.appending(path: "src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("a".utf8).write(to: source.appending(path: "a.txt"))
        try Data("b".utf8).write(to: source.appending(path: "b.txt"))

        func zip(_ items: [String], as name: String) throws -> URL {
            let archive = folder.appending(path: name)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/zip")
            process.currentDirectoryURL = source
            process.arguments = ["-q", archive.path] + items
            try process.run()
            process.waitUntilExit()
            return archive
        }
        let single = try zip(["a.txt"], as: "Single.zip")
        let multi = try zip(["a.txt", "b.txt"], as: "Pair.zip")
        try FileManager.default.removeItem(at: source.appending(path: "a.txt"))
        await DownloadsWatcher.unzip(single)
        await DownloadsWatcher.unzip(multi)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertTrue(names.contains("a.txt"), "single item comes out as is")
        XCTAssertTrue(names.contains("Pair"), "several items go in a folder named after the zip")
        XCTAssertFalse(names.contains("Single.zip"))
        XCTAssertFalse(names.contains("Pair.zip"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Pair").path)), ["a.txt", "b.txt"])
    }

    func testUniqueNames() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unique-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "Clip.mov"))
        XCTAssertEqual(DownloadsWatcher.uniqueURL(for: "Clip.mov", in: folder).lastPathComponent, "Clip 2.mov")
        XCTAssertEqual(DownloadsWatcher.uniqueURL(for: "New.mov", in: folder).lastPathComponent, "New.mov")
    }
}

@MainActor
final class NetworkTweakTests: XCTestCase {
    func testWiFiDecisions() {
        XCTAssertEqual(WiFiWhenWired.decision(wired: true, wifiOn: true, turnedOffByTweaks: false), .turnOff)
        XCTAssertEqual(WiFiWhenWired.decision(wired: true, wifiOn: false, turnedOffByTweaks: false), .nothing)
        XCTAssertEqual(WiFiWhenWired.decision(wired: false, wifiOn: false, turnedOffByTweaks: true), .turnOn)
        XCTAssertEqual(WiFiWhenWired.decision(wired: false, wifiOn: false, turnedOffByTweaks: false), .nothing,
                       "Wi-Fi you turned off yourself stays off")
    }

    func testWiFiDeviceParsing() {
        let output = "Hardware Port: Ethernet\nDevice: en1\n\nHardware Port: Wi-Fi\nDevice: en0\nEthernet Address: aa\n"
        XCTAssertEqual(WiFiPower.parseDevice(output), "en0")
        XCTAssertEqual(WiFiPower.device(), "en0", "this Mac's Wi-Fi")
    }

    func testShareURLs() {
        XCTAssertEqual(NetworkShares.serverURL(type: "smbfs", mountedFrom: "//role@ath01-nas.uwia.wisc.edu/users")?.absoluteString,
                       "smb://ath01-nas.uwia.wisc.edu/users")
        XCTAssertEqual(NetworkShares.serverURL(type: "nfs", mountedFrom: "nas:/export/media")?.absoluteString, "nfs://nas/export/media")
        XCTAssertNil(NetworkShares.serverURL(type: "apfs", mountedFrom: "/dev/disk3s1"))
    }

    func testOnlyMissingSharesMount() {
        let wanted = [URL(string: "smb://ath01-nas.uwia.wisc.edu/users/")!, URL(string: "smb://other/media")!]
        let mounted = [URL(string: "smb://ATH01-NAS.uwia.wisc.edu/users")!]
        XCTAssertEqual(ShareAutoConnect.sharesToMount(wanted: wanted, mounted: mounted).map(\.absoluteString), ["smb://other/media"])
    }

    /// Live, against this Mac: the NAS share is mounted, its server answers, and asking
    /// to mount it again is a harmless no-op.
    func testLiveShareChecks() async throws {
        guard let share = NetworkShares.mounted().first else { throw XCTSkip("no network share mounted") }
        let reachable = await NetworkShares.isReachable(share.serverURL)
        XCTAssertTrue(reachable)
        let remount = await NetworkShares.mount(share.serverURL)
        XCTAssertTrue(remount, "an already-mounted share reports success")
        let bogus = await NetworkShares.isReachable(URL(string: "smb://nonexistent-host.invalid/share")!)
        XCTAssertFalse(bogus)
    }

    func testBluetoothFunctionsExist() {
        XCTAssertTrue(BluetoothPower.isAvailable, "IOBluetooth power functions still present on this macOS")
    }
}
