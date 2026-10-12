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
        XCTAssertTrue(Tweak.allCases.allSatisfy(settings.isOn))
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
