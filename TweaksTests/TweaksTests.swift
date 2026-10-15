import Carbon.HIToolbox
import Darwin
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

    func testFilenameCompletionMatchesURLRules() {
        for name in ["Clip.CRDOWNLOAD", "movie.mp4.partial", "done file.MOV", "plain", ".download",
                     "末尾.mov.part", "encoded%20file.opdownload", "photo.JPG", "a..part", "file.tmp"] {
            let url = URL(fileURLWithPath: "/tmp/" + name)
            let partial: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "tmp"]
            XCTAssertEqual(DownloadsWatcher.isFinishedDownload(named: name),
                           !partial.contains(url.pathExtension.lowercased()), name)
        }
    }

    func testDirectorySnapshotPreservesNamesAndReportsFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["a.mov", "résumé.JPG", "末尾.mov.part", ".hidden", "with spaces.MOV"]
        for name in names { try Data().write(to: folder.appending(path: name)) }
        XCTAssertEqual(Set(try XCTUnwrap(DownloadDirectory.names(in: folder))), Set(names))
        XCTAssertNil(DownloadDirectory.names(in: folder.appending(path: "missing")))
        XCTAssertNil(DownloadDirectory.names(in: folder.appending(path: "a.mov")))
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

    func testRenamePreservesExistingDestination() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Different names exercise the same overwrite primitive on either filesystem case mode.
        let source = folder.appending(path: "Source.MOV")
        let destination = folder.appending(path: "Existing.mov")
        try Data("new".utf8).write(to: source)
        try Data("original".utf8).write(to: destination)
        XCTAssertFalse(DownloadsWatcher.moveCaseOnly(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }

    func testRenamePreservesExistingHardLink() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Source.MOV")
        let destination = folder.appending(path: "Existing.mov")
        try Data("original".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: destination)
        XCTAssertFalse(DownloadsWatcher.moveCaseOnly(from: source, to: destination))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       ["Source.MOV", "Existing.mov"])
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }
}

@MainActor
final class BackgroundPerformanceTests: XCTestCase {
    func testProcessSampling() {
        var sampler = CPUSampler()
        benchmark("render_poll") { _ = RenderKeepAwake.sampleBusyRenderer(using: &sampler) }
    }

    func testThousandLinkCleanups() {
        benchmark("1000_link_cleanups") {
            for _ in 0..<1_000 {
                XCTAssertEqual(LinkCleaner.clean("https://www.youtube.com/watch?v=abc&si=TRACK&t=42&utm_source=email"),
                               "https://www.youtube.com/watch?v=abc&t=42")
            }
        }
    }

    func testTenThousandExistingDownloads() async throws {
        let folder = try downloadFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        await benchmarkAsync("10000_existing_downloads_scan") { await watcher.scan() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 10_000)
    }

    func testTenThousandDownloadCompletionCheck() throws {
        let folder = try downloadFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        benchmark("10000_downloads_completion_check") {
            XCTAssertFalse(JobWatcher.downloadsInProgress(in: folder))
        }
    }

    private func downloadFixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "benchmark-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for index in 0..<10_000 { try Data().write(to: folder.appending(path: "Clip-\(index).MOV")) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Warm each operation, then report wall latency and process CPU for the same work.
    /// No timing assertions: background workload makes portable speed limits misleading.
    private func benchmark(_ name: String, operation: () -> Void) {
        for _ in 0..<5 { operation() }
        var wall: [Double] = []
        var cpu: [Double] = []
        for _ in 0..<30 {
            let cpuStart = processCPUTime()
            let start = ContinuousClock.now
            operation()
            let elapsed = start.duration(to: .now).components
            wall.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            cpu.append(processCPUTime() - cpuStart)
        }
        let sorted = wall.sorted()
        let result: [String: Any] = ["name": name, "samples": wall.count,
                                   "wall_median_ms": (sorted[14] + sorted[15]) / 2,
                                   "wall_p95_ms": sorted[28],
                                   "cpu_mean_ms": cpu.reduce(0, +) / Double(cpu.count)]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("PERF_RESULT " + String(decoding: data, as: UTF8.self))
    }

    private func benchmarkAsync(_ name: String, operation: () async -> Void) async {
        for _ in 0..<5 { await operation() }
        var wall: [Double] = []
        var cpu: [Double] = []
        for _ in 0..<30 {
            let cpuStart = processCPUTime()
            let start = ContinuousClock.now
            await operation()
            let elapsed = start.duration(to: .now).components
            wall.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            cpu.append(processCPUTime() - cpuStart)
        }
        let sorted = wall.sorted()
        let result: [String: Any] = ["name": name, "samples": wall.count,
                                   "wall_median_ms": (sorted[14] + sorted[15]) / 2,
                                   "wall_p95_ms": sorted[28],
                                   "cpu_mean_ms": cpu.reduce(0, +) / Double(cpu.count)]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("PERF_RESULT " + String(decoding: data, as: UTF8.self))
    }

    private func processCPUTime() -> Double {
        var time = timespec()
        XCTAssertEqual(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time), 0)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1e6
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
        XCTAssertTrue(Tweak.allCases.allSatisfy { settings.isOn($0) == $0.defaultEnabled })
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
    func testFailedDirectoryReadDoesNotForgetExistingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "read-failure-\(UUID().uuidString)")
        let folder = root.appending(path: "Downloads")
        let moved = root.appending(path: "TemporarilyMoved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: folder.appending(path: "Existing.JPG"))
        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        try FileManager.default.moveItem(at: folder, to: moved)
        await watcher.scan()
        try FileManager.default.moveItem(at: moved, to: folder)
        let now = Date()
        await watcher.scan(now: now)
        await watcher.scan(now: now.addingTimeInterval(DownloadsWatcher.settleTime))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Existing.JPG"])
    }

    func testNameOnlyScanStillSkipsHiddenFilesAndDirectories() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        for name in ["Folder.JPG", "Example.APP"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        for name in [".Dot.JPG", "Flagged.JPG", "Visible.JPG"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
        var hidden = folder.appending(path: "Flagged.JPG")
        var attributes = URLResourceValues()
        attributes.isHidden = true
        try hidden.setResourceValues(attributes)
        let now = Date()
        await watcher.scan(now: now)
        await watcher.scan(now: now.addingTimeInterval(DownloadsWatcher.settleTime))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       ["Folder.JPG", "Example.APP", ".Dot.JPG", "Flagged.JPG", "Visible.jpg"])
    }

    func testGrowingFileRestartsItsSettleInterval() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "growth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Clip.MOV")
        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        let now = Date()
        try Data("x".utf8).write(to: source)
        await watcher.scan(now: now)
        try Data("still growing".utf8).write(to: source)
        await watcher.scan(now: now.addingTimeInterval(3))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Clip.MOV"])
        await watcher.scan(now: now.addingTimeInterval(4))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Clip.MOV"])
        await watcher.scan(now: now.addingTimeInterval(5))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Clip.mov"])
    }

    func testRestartGivesReplacementDownloadAFreshSettleInterval() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Photo.JPG")
        let now = Date()
        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        try Data("old".utf8).write(to: source)
        let modified = try XCTUnwrap(source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        await watcher.scan(now: now)
        watcher.stop()
        try FileManager.default.removeItem(at: source)
        watcher.start()
        await watcher.waitUntilReady()
        try Data("new".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)

        await watcher.scan(now: now.addingTimeInterval(10))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Photo.JPG"])
        await watcher.scan(now: now.addingTimeInterval(10 + DownloadsWatcher.settleTime))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Photo.jpg"])
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "Photo.jpg")), Data("new".utf8))
    }

    func testWatcherLowercasesNewDownloads() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appending(path: "Existing.PNG"))

        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        try Data("new".utf8).write(to: folder.appending(path: "Photo.JPG"))

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            if FileManager.default.fileExists(atPath: folder.appending(path: "Photo.jpg").path),
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains("Photo.jpg") == true { break }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["Existing.PNG", "Photo.jpg"], "new file renamed, existing file left alone")
    }
}

final class CPUSamplerTests: XCTestCase {
    private let ae = "/Applications/Adobe After Effects 2026/Adobe After Effects 2026.app/Contents/MacOS/After Effects"

    func testCPUIsAggregatedAcrossRenderProcesses() {
        var now: UInt64 = 100
        var readings = [CPUSampler.Reading(pid: 1, path: ae, ticks: 100, startedAt: 1),
                        CPUSampler.Reading(pid: 2, path: ae, ticks: 200, startedAt: 2)]
        var sampler = CPUSampler(readProcesses: { readings }, clock: { now })
        XCTAssertTrue(sampler.sample().isEmpty, "first sample establishes CPU counters")
        now = 200
        readings = [.init(pid: 1, path: ae, ticks: 150, startedAt: 1),
                    .init(pid: 2, path: ae, ticks: 225, startedAt: 2)]
        let usage = sampler.sample()
        XCTAssertEqual(usage[ae], 75)
        XCTAssertEqual(RenderKeepAwake.busyRenderer(in: usage), "After Effects")
    }

    func testIdleOrUnreadableRenderEngineStillHoldsAwake() {
        for path in ["/Adobe/aerender", "/Adobe/aerendercore", "/Adobe After Effects Render Engine/App"] {
            var readings = [CPUSampler.Reading(pid: 1, path: path, ticks: nil, startedAt: 0)]
            var sampler = CPUSampler(readProcesses: { readings }, clock: { 100 })
            XCTAssertEqual(RenderKeepAwake.sampleBusyRenderer(using: &sampler), "aerender", path)
            readings = []
            XCTAssertNil(RenderKeepAwake.sampleBusyRenderer(using: &sampler), "exited process clears presence")
        }
    }

    func testPIDReuseAndCounterResetCannotInventCPUUsage() {
        var now: UInt64 = 100
        var reading = CPUSampler.Reading(pid: 1, path: ae, ticks: 100, startedAt: 1)
        var sampler = CPUSampler(readProcesses: { [reading] }, clock: { now })
        _ = sampler.sample()
        now = 200
        reading = .init(pid: 1, path: ae, ticks: 10_000, startedAt: 2)
        XCTAssertTrue(sampler.sample().isEmpty, "new process reused the PID")
        now = 300
        reading = .init(pid: 1, path: ae, ticks: 1, startedAt: 2)
        XCTAssertTrue(sampler.sample().isEmpty, "counter decreased")
        reading = .init(pid: 1, path: ae, ticks: 100, startedAt: 2)
        XCTAssertTrue(sampler.sample().isEmpty, "same timestamp gives no rate")
    }

    func testIdleForegroundAppIsNotAnIdleRenderEngine() {
        var sampler = CPUSampler(readProcesses: { [.init(pid: 1, path: self.ae, ticks: 0, startedAt: 1)] },
                                 clock: { 100 })
        XCTAssertNil(RenderKeepAwake.sampleBusyRenderer(using: &sampler))
        XCTAssertFalse(sampler.hasRenderProcess)
    }

    func testLiveEnumerationFindsAWaitingRenderer() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "renderer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "aerender")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: executable)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        var sampler = CPUSampler()
        XCTAssertEqual(RenderKeepAwake.sampleBusyRenderer(using: &sampler), "aerender")
        let usage = sampler.sample()
        XCTAssertTrue(usage.keys.contains {
            URL(filePath: $0).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
        }, "libproc may report /private/var where Foundation reports /var")
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
    func testShareURLs() {
        XCTAssertEqual(NetworkShares.serverURL(type: "smbfs", mountedFrom: "//user@nas.example.edu/users")?.absoluteString,
                       "smb://nas.example.edu/users")
        XCTAssertEqual(NetworkShares.serverURL(type: "nfs", mountedFrom: "nas:/export/media")?.absoluteString, "nfs://nas/export/media")
        XCTAssertNil(NetworkShares.serverURL(type: "apfs", mountedFrom: "/dev/disk3s1"))
    }

    func testOnlyMissingSharesMount() {
        let wanted = [URL(string: "smb://nas.example.edu/users/")!, URL(string: "smb://other/media")!]
        let mounted = [URL(string: "smb://NAS.example.edu/users")!]
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

}

@MainActor
final class HardeningTests: XCTestCase {
    private func identity(_ version: String?, team: String?) -> AppIdentity {
        AppIdentity(name: "App", bundleID: "com.example.app", version: version, teamID: team)
    }

    func testDMGRefusesDowngradesAndImpostors() {
        XCTAssertNil(DMGInstaller.problem(installing: identity("2.1", team: "T1"), over: nil), "fresh install")
        XCTAssertNil(DMGInstaller.problem(installing: identity("2.10", team: "T1"), over: identity("2.9", team: "T1")))
        XCTAssertNotNil(DMGInstaller.problem(installing: identity("2.8", team: "T1"), over: identity("2.9", team: "T1")))
        XCTAssertNotNil(DMGInstaller.problem(installing: identity("3.0", team: "EVIL"), over: identity("2.9", team: "T1")))
    }

    func testAppIdentityReadsRealApp() async {
        let finder = await AppIdentity.read(URL(filePath: "/Applications/Safari.app"))
        XCTAssertEqual(finder.bundleID, "com.apple.Safari")
        XCTAssertNotNil(finder.version)
    }

    func testOpenFileDetection() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "open-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(OpenFiles.isOpen(url.path))
        // A child process holding the file open is seen.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "exec 3<\"\(url.path)\"; sleep 3"]
        try process.run()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(OpenFiles.isOpen(url.path))
        process.terminate()
    }

    func testRendererMatching() {
        XCTAssertTrue(RenderProcesses.isRenderer("/Applications/Adobe After Effects 2026/aerender"))
        XCTAssertTrue(RenderProcesses.isRenderer("/Applications/Adobe After Effects 2026/Adobe After Effects Render Engine 2026.app/Contents/MacOS/AfterFX"))
        XCTAssertFalse(RenderProcesses.isRenderer("/Applications/Dia.app/Contents/MacOS/Dia"))
    }

    func testUnzipRefusesEscapingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "inner/ok").path, withDestinationPath: "../inner")
        XCTAssertFalse(DownloadsWatcher.containsEscapingSymlink(in: root))
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "home").path, withDestinationPath: NSHomeDirectory())
        XCTAssertTrue(DownloadsWatcher.containsEscapingSymlink(in: root))
    }

    func testShareMatchedByNameAcrossAddresses() {
        let wanted = [URL(string: "smb://nas.example.edu/users")!]
        XCTAssertTrue(ShareAutoConnect.sharesToMount(wanted: wanted, mounted: [URL(string: "smb://10.1.2.3/users")!]).isEmpty)
    }

    func testQuitNeedsTwoEmptyAnswers() {
        XCTAssertFalse(LastWindowQuitter.shouldQuit(hadWindows: true, windowCount: 0, emptyPolls: 1))
        XCTAssertTrue(LastWindowQuitter.shouldQuit(hadWindows: true, windowCount: 0, emptyPolls: 2))
    }

    func testGreenButtonCorner() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(GreenButtonFill.isInCorner(CGPoint(x: 150, y: 110), of: window))
        XCTAssertFalse(GreenButtonFill.isInCorner(CGPoint(x: 500, y: 400), of: window))
    }
}

@MainActor
final class KeepAwakeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEndReasons() {
        let running: (pid_t) -> Bool = { _ in true }
        XCTAssertNil(KeepAwake.endReason(for: .indefinitely, now: now, isRunning: running, battery: nil))
        XCTAssertNotNil(KeepAwake.endReason(for: .date(now.addingTimeInterval(-1)), now: now, isRunning: running, battery: nil))
        XCTAssertNil(KeepAwake.endReason(for: .date(now.addingTimeInterval(60)), now: now, isRunning: running, battery: nil))
        XCTAssertEqual(KeepAwake.endReason(for: .appQuits(pid: 42, name: "Media Encoder"), now: now, isRunning: { _ in false }, battery: nil),
                       "Media Encoder quit.")
        XCTAssertNil(KeepAwake.endReason(for: .done(.render), now: now, isRunning: running, battery: nil), "jobs are judged by JobWatcher")
        XCTAssertNotNil(KeepAwake.endReason(for: .indefinitely, now: now, isRunning: running, battery: Battery(percent: 12, pluggedIn: false)),
                        "low battery ends any session")
        XCTAssertNil(KeepAwake.endReason(for: .indefinitely, now: now, isRunning: running, battery: Battery(percent: 12, pluggedIn: true)))
    }

    func testLinkParsing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        XCTAssertEqual(KeepAwake.until(minutes: "45", hours: nil, time: nil, now: now), .date(now.addingTimeInterval(2700)))
        XCTAssertEqual(KeepAwake.until(minutes: nil, hours: "1.5", time: nil, now: now), .date(now.addingTimeInterval(5400)))
        guard case let .date(end)? = KeepAwake.until(minutes: nil, hours: nil, time: "18:30", now: now, calendar: calendar) else {
            return XCTFail("time not parsed")
        }
        XCTAssertGreaterThan(end, now)
        XCTAssertEqual(calendar.component(.hour, from: end), 18)
        XCTAssertNil(KeepAwake.until(minutes: nil, hours: nil, time: "25:00", now: now))
        XCTAssertNil(KeepAwake.until(minutes: "-5", hours: nil, time: nil, now: now))
    }

    func testSuggestedTimesAreAheadAndSorted() {
        let times = KeepAwake.suggestedEndTimes(from: now)
        XCTAssertFalse(times.isEmpty)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.allSatisfy { $0.timeIntervalSince(now) >= 600 })
    }
}

@MainActor
final class KeepAwakeEnhancementTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testJobDoneAfterQuietPeriod() {
        var quiet: Date?
        // Busy, then quiet for less than the period: not done.
        XCTAssertFalse(JobWatcher.decide(busy: true, quietSince: &quiet, startedAt: start, now: start, quietPeriod: 60))
        XCTAssertFalse(JobWatcher.decide(busy: false, quietSince: &quiet, startedAt: start, now: start.addingTimeInterval(30), quietPeriod: 60))
        XCTAssertFalse(JobWatcher.decide(busy: false, quietSince: &quiet, startedAt: start, now: start.addingTimeInterval(60), quietPeriod: 60))
        // Quiet for the full period: done.
        XCTAssertTrue(JobWatcher.decide(busy: false, quietSince: &quiet, startedAt: start, now: start.addingTimeInterval(95), quietPeriod: 60))
        // A burst of work resets the clock.
        var again: Date? = start
        XCTAssertFalse(JobWatcher.decide(busy: true, quietSince: &again, startedAt: start, now: start.addingTimeInterval(100), quietPeriod: 60))
        XCTAssertNil(again)
    }

    func testCountdownLabels() {
        XCTAssertEqual(KeepAwake.countdown(until: .date(start.addingTimeInterval(3 * 3600 + 12 * 60 + 30)), now: start), "3h 12m")
        XCTAssertEqual(KeepAwake.countdown(until: .date(start.addingTimeInterval(45 * 60)), now: start), "45m")
        XCTAssertEqual(KeepAwake.countdown(until: .done(.render), now: start), "render")
        XCTAssertNil(KeepAwake.countdown(until: .indefinitely, now: start))
    }

    func testLinkNamesForJobs() {
        XCTAssertEqual(JobCondition(linkName: "render"), .render)
        XCTAssertEqual(JobCondition(linkName: "copy"), .nasCopy)
        XCTAssertNil(JobCondition(linkName: "nope"))
    }

    func testDownloadsInProgressDetection() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "done.mov"))
        XCTAssertFalse(JobWatcher.downloadsInProgress(in: folder))
        try Data().write(to: folder.appending(path: "big.mov.crdownload"))
        XCTAssertTrue(JobWatcher.downloadsInProgress(in: folder))
    }

    func testUploadCounterReads() {
        XCTAssertGreaterThan(JobWatcher.uploadedBytes(), 0, "this Mac has sent bytes since boot")
    }

    func testChoicesRoundTrip() throws {
        let choices: [Choice] = [.hours(12), .indefinitely, .done(.upload), .app(bundleID: "com.adobe.ame.application.26", name: "Media Encoder")]
        let decoded = try JSONDecoder().decode([Choice].self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(decoded, choices)
        XCTAssertEqual(Choice.hours(12).title, "12 hours")
        XCTAssertEqual(Choice.done(.render).title, "Render finishes")
    }
}

@MainActor
final class ShortcutTests: XCTestCase {
    private func store() -> ShortcutStore {
        ShortcutStore(defaults: UserDefaults(suiteName: "ShortcutTests-\(UUID().uuidString)")!)
    }

    func testDefaultsAndLabels() {
        let shortcuts = store()
        XCTAssertEqual(shortcuts.shortcut(for: .keepAwake)?.label, "Hyper /")
        XCTAssertEqual(shortcuts.shortcut(for: .clearNotifications)?.label, "Hyper N")
        XCTAssertNil(shortcuts.shortcut(for: .screenOff))
        let custom = Shortcut(keyCode: 45, modifiers: UInt32(cmdKey | optionKey), key: "N")
        XCTAssertEqual(custom.label, "⌥⌘N")
    }

    func testReassigningStealsFromTheOldAction() {
        let shortcuts = store()
        let hyperSlash = shortcuts.shortcut(for: .keepAwake)
        shortcuts.set(hyperSlash, for: .screenOff)
        XCTAssertEqual(shortcuts.shortcut(for: .screenOff), hyperSlash)
        XCTAssertNil(shortcuts.shortcut(for: .keepAwake), "one set of keys, one action")
    }

    func testCapsLockRestoreUsesSavedDelayOrTheSystemDefault() {
        XCTAssertNil(CapsLockDelay.parse(hidutilOutput: "(null)\n"))
        XCTAssertNil(CapsLockDelay.parse(hidutilOutput: ""))
        XCTAssertEqual(CapsLockDelay.parse(hidutilOutput: #"{"CapsLockDelayOverride":0}"#), 0)
        XCTAssertEqual(CapsLockDelay.parse(hidutilOutput: #"{"CapsLockDelayOverride":100000000}"#), 100_000_000)
        XCTAssertNil(CapsLockDelay.original(from: nil))
        XCTAssertNil(CapsLockDelay.original(from: 0), "the tweak's own value is not an original setting")
        XCTAssertEqual(CapsLockDelay.original(from: 100_000_000), 100_000_000)
        XCTAssertEqual(CapsLockDelay.restoreNanoseconds(saved: 80_000_000), 80_000_000)
        XCTAssertEqual(CapsLockDelay.restoreNanoseconds(saved: nil), CapsLockDelay.systemDefaultNanoseconds)
        XCTAssertEqual(CapsLockDelay.restoreNanoseconds(saved: 0), CapsLockDelay.systemDefaultNanoseconds)

        let defaults = UserDefaults(suiteName: "CapsLock-\(UUID().uuidString)")!
        var written: [Int] = []
        CapsLockTweak.apply(defaults: defaults, reader: { 100_000_000 }, writer: { written.append($0) })
        CapsLockTweak.apply(defaults: defaults, reader: { 0 }, writer: { written.append($0) })
        CapsLockTweak.restore(defaults: defaults, writer: { written.append($0) })
        XCTAssertEqual(written, [0, 0, 100_000_000])
        XCTAssertEqual(defaults.integer(forKey: CapsLockDelay.savedKey), 100_000_000)
    }

    func testGreenButtonRemembersTheFrameItFilledFrom() {
        let original = CGRect(x: 40, y: 80, width: 640, height: 400)
        let filled = CGRect(x: 0, y: 25, width: 1440, height: 900)
        XCTAssertEqual(GreenButtonFill.decision(frame: original, target: filled, saved: nil), GreenButtonFill.FillDecision.fill(save: original))
        XCTAssertEqual(GreenButtonFill.decision(frame: filled, target: filled, saved: original), GreenButtonFill.FillDecision.restore(original))
        XCTAssertEqual(GreenButtonFill.decision(frame: filled, target: filled, saved: nil), GreenButtonFill.FillDecision.fill(save: filled))
    }

    func testRendererSamplerSkipsUnrelatedProcesses() {
        XCTAssertTrue(CPUSampler.shouldMeasure("/Applications/Adobe After Effects 2026/Adobe After Effects 2026.app/Contents/MacOS/After Effects"))
        XCTAssertTrue(CPUSampler.shouldMeasure("/Applications/Adobe After Effects 2026/aerender"))
        XCTAssertFalse(CPUSampler.shouldMeasure("/Applications/Adobe After Effects 2026/Adobe After Effects 2026.app/Contents/MacOS/After Effects Helper"))
        XCTAssertFalse(CPUSampler.shouldMeasure("/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    func testHiddenUIDoesNotInstallADisplayLink() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Tweaks/SettingsView.swift", "Tweaks/HUD.swift", "Tweaks/KeepAwakePanel.swift"]
        for relative in files {
            let source = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
            for banned in ["titlebarAppearsTransparent", "animator(", "NSAnimationContext"] {
                XCTAssertFalse(source.contains(banned), "\(relative) \(banned)")
            }
        }
    }

    func testIdleWorkIsNotOnATightLoop() {
        XCTAssertGreaterThanOrEqual(LinkCleaner.pollInterval, 2)
        XCTAssertGreaterThanOrEqual(ShortcutBannerDismisser.pollInterval, 3)
        XCTAssertGreaterThanOrEqual(LastWindowQuitter.pollInterval, 2)
        XCTAssertGreaterThanOrEqual(RenderKeepAwake.idleInterval, 30)
        XCTAssertGreaterThanOrEqual(KeepAwake.watchInterval, 20)
        XCTAssertGreaterThanOrEqual(ShareAutoConnect.pollInterval, 180)
        XCTAssertGreaterThanOrEqual(CapsLockTweak.reapplyInterval, 300)
        XCTAssertGreaterThanOrEqual(TweakController.accessibilityInterval, 30)
        XCTAssertFalse(ShortcutBannerDismisser.shortcutsMightBeRunning([]))
    }

    func testIdleProcessDoesNotLinkTheHeavyFrameworks() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let tweaks = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Tweaks"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let finder = try FileManager.default.contentsOfDirectory(at: root.appending(path: "FinderSync"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(tweaks.isEmpty)
        XCTAssertFalse(finder.isEmpty)
        for url in tweaks {
            let source = try String(contentsOf: url, encoding: .utf8)
            for banned in ["import SwiftUI", "import FinderSync", "import AudioToolbox"] {
                XCTAssertFalse(source.contains(banned), "\(url.lastPathComponent) \(banned)")
            }
        }
        for url in finder {
            let source = try String(contentsOf: url, encoding: .utf8)
            for banned in ["import AVFoundation", "import ImageIO", "import Cocoa"] {
                XCTAssertFalse(source.contains(banned), "\(url.lastPathComponent) \(banned)")
            }
        }
    }

    func testClearedShortcutStaysCleared() {
        let defaults = UserDefaults(suiteName: "ShortcutTests-\(UUID().uuidString)")!
        ShortcutStore(defaults: defaults).set(nil, for: .clearNotifications)
        XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: .clearNotifications), "removing a default sticks")
    }
}
