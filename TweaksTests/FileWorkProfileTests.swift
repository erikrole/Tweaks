import Darwin
import XCTest
@testable import Tweaks

/// Opt-in controlled profiles: run this class with TWEAKS_FILE_PROFILE=1 in the test host.
@MainActor
final class FileWorkProfileTests: XCTestCase {
    func testNewDownloadBurst() async throws {
        try requireProfile()
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = DownloadsWatcher(folder: folder)
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        var samples: [FileWorkSample] = []
        for run in 0..<6 {
            for index in 0..<100 {
                try Data("download".utf8).write(to: folder.appending(path: "Burst-\(run)-\(index).TXT"))
            }
            let now = Date()
            await watcher.scan(now: now)
            let sample = await profile { await watcher.scan(now: now.addingTimeInterval(2)) }
            if run > 0 { samples.append(sample) }
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            XCTAssertEqual(names.filter { $0.hasSuffix(".txt") }.count, (run + 1) * 100)
        }
        report("100_new_downloads", samples)
    }

    func testArchiveWithTwoThousandFiles() async throws {
        try requireProfile()
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source/Payload")
        let destination = root.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for index in 0..<2_000 { try Data("zip fixture".utf8).write(to: source.appending(path: "File-\(index).txt")) }
        let template = root.appending(path: "template.zip")
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", template.path, "Payload"]
        zip.currentDirectoryURL = source.deletingLastPathComponent()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        var samples: [FileWorkSample] = []
        for run in 0..<6 {
            let archive = destination.appending(path: "Archive.zip")
            try FileManager.default.copyItem(at: template, to: archive)
            let sample = await profile { await DownloadsWatcher.unzip(archive) }
            if run > 0 { samples.append(sample) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
            let extracted = destination.appending(path: "Payload")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.path).count, 2_000)
            try FileManager.default.removeItem(at: extracted)
        }
        report("zip_2000_files", samples)
    }

    private func requireProfile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TWEAKS_FILE_PROFILE"] == "1")
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tweaks-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func profile(_ work: () async -> Void) async -> FileWorkSample {
        let pulse = MainThreadPulse()
        pulse.start()
        try? await Task.sleep(for: .milliseconds(20))
        pulse.reset()
        let cpu = threadCPU()
        let begin = DispatchTime.now().uptimeNanoseconds
        await work()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
        let mainCPU = threadCPU() - cpu
        // Let the timer record a callback delayed by the final synchronous portion.
        try? await Task.sleep(for: .milliseconds(20))
        pulse.stop()
        return FileWorkSample(wall: elapsed, mainCPU: mainCPU, maxDelay: pulse.maxDelay)
    }

    private func threadCPU() -> Double {
        var time = timespec()
        XCTAssertEqual(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time), 0)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1e6
    }

    private func report(_ name: String, _ samples: [FileWorkSample]) {
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let result: [String: Any] = ["name": name, "samples": samples.count,
            "wall_median_ms": median(samples.map(\.wall)),
            "main_cpu_median_ms": median(samples.map(\.mainCPU)),
            "max_main_delay_median_ms": median(samples.map(\.maxDelay)),
            "max_main_delay_worst_ms": samples.map(\.maxDelay).max()!]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("FILE_PROFILE " + String(decoding: data, as: UTF8.self))
    }
}

private struct FileWorkSample {
    let wall: Double
    let mainCPU: Double
    let maxDelay: Double
}

@MainActor
private final class MainThreadPulse {
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var last: UInt64 = 0
    private(set) var maxDelay: Double = 0

    func start() {
        last = DispatchTime.now().uptimeNanoseconds
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                self.maxDelay = max(self.maxDelay, Double(now - self.last) / 1e6 - 2)
                self.last = now
            }
        }
        timer.resume()
    }

    func reset() { maxDelay = 0; last = DispatchTime.now().uptimeNanoseconds }
    func stop() { timer.cancel() }
}
