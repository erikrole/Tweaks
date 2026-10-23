import XCTest
@testable import Tweaks

@MainActor
final class FileWorkConcurrencyTests: XCTestCase {
    func testStoppingDuringOpenFileCheckPreventsRenameAndRestartForgetsCandidates() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entered = expectation(description: "background open-file check")
        let gate = DispatchSemaphore(value: 0)
        let calls = LockedCalls()
        let watcher = DownloadsWatcher(folder: folder, fileIsOpen: { _ in
            XCTAssertFalse(Thread.isMainThread)
            if calls.increment() == 1 {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            }
            return false
        })
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        try Data("old".utf8).write(to: folder.appending(path: "Old.JPG"))
        let now = Date()
        await watcher.scan(now: now)
        let scan = Task { await watcher.scan(now: now.addingTimeInterval(2)) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(watcher.isBusy)
        watcher.stop()
        XCTAssertTrue(watcher.isBusy, "stopped sessions can still be draining file work")
        watcher.start()
        await watcher.waitUntilReady()
        XCTAssertTrue(watcher.isBusy, "a new watcher must not hide the old transaction")
        gate.signal()
        await scan.value
        XCTAssertFalse(watcher.isBusy)
        XCTAssertEqual(try names(in: folder), ["Old.JPG"])

        try Data("new".utf8).write(to: folder.appending(path: "New.JPG"))
        await watcher.scan(now: now.addingTimeInterval(10))
        XCTAssertEqual(try names(in: folder), ["New.JPG", "Old.JPG"])
        await watcher.scan(now: now.addingTimeInterval(12))
        XCTAssertEqual(try names(in: folder), ["New.jpg", "Old.JPG"])
    }

    func testDisablingRenameDuringOpenFileCheckUsesCurrentOptions() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entered = expectation(description: "background open-file check")
        let gate = DispatchSemaphore(value: 0)
        let watcher = DownloadsWatcher(folder: folder, fileIsOpen: { _ in
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return false
        })
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        try Data("x".utf8).write(to: folder.appending(path: "Photo.JPG"))
        let now = Date()
        await watcher.scan(now: now)
        let scan = Task { await watcher.scan(now: now.addingTimeInterval(2)) }
        await fulfillment(of: [entered], timeout: 3)
        watcher.lowercaseExtensions = false
        gate.signal()
        await scan.value
        XCTAssertEqual(try names(in: folder), ["Photo.JPG"])
    }

    func testOverlappingScansHandleAFileOnce() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = LockedCalls()
        let watcher = DownloadsWatcher(folder: folder, fileIsOpen: { _ in
            XCTAssertFalse(Thread.isMainThread)
            _ = calls.increment()
            return false
        })
        watcher.lowercaseExtensions = true
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        try Data("x".utf8).write(to: folder.appending(path: "Photo.JPG"))
        let now = Date()
        await watcher.scan(now: now)
        let first = Task { await watcher.scan(now: now.addingTimeInterval(2)) }
        let second = Task { await watcher.scan(now: now.addingTimeInterval(2)) }
        await first.value
        await second.value
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try names(in: folder), ["Photo.jpg"])
    }

    func testStopBeforeStartupCannotProcessFiles() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "test.delayed-file-start")
        queue.suspend()
        let watcher = DownloadsWatcher(folder: folder, queue: queue)
        watcher.lowercaseExtensions = true
        watcher.start()
        XCTAssertFalse(watcher.isRunning, "a queued start is not yet watching")
        watcher.stop()
        try Data("x".utf8).write(to: folder.appending(path: "Photo.JPG"))
        queue.resume()
        try await FileWork.run(on: queue) {}
        XCTAssertFalse(watcher.isRunning)
        XCTAssertEqual(try names(in: folder), ["Photo.JPG"])
    }

    func testArchiveBacklogDoesNotDelayWatcherStartup() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        FileWork.queue.suspend()
        defer { FileWork.queue.resume() }
        let watcher = DownloadsWatcher(folder: folder, fileIsOpen: { _ in false })
        watcher.lowercaseExtensions = true
        watcher.start()
        defer { watcher.stop() }
        await watcher.waitUntilReady()
        XCTAssertTrue(watcher.isRunning)
        try Data("x".utf8).write(to: folder.appending(path: "New.JPG"))
        let now = Date()
        await watcher.scan(now: now)
        await watcher.scan(now: now.addingTimeInterval(2))
        XCTAssertEqual(try names(in: folder), ["New.jpg"])
    }

    func testFileWorkerIsSerialAndOffMain() async throws {
        let active = LockedCalls()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await FileWork.run {
                        XCTAssertFalse(Thread.isMainThread)
                        XCTAssertEqual(active.increment(), 1)
                        Thread.sleep(forTimeInterval: 0.002)
                        active.decrement()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(active.count, 0)
    }

    func testCancelledArchiveKeepsOriginal() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appending(path: "Original.zip")
        let original = Data("unchanged archive".utf8)
        try original.write(to: archive)
        await DownloadsWatcher.unzip(archive, shouldContinue: { false })
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try names(in: folder), ["Original.zip"])
    }

    func testQueuedArchiveRejectsReplacementBeforeExtraction() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try makeArchive(in: folder)
        let version = try XCTUnwrap(FileVersion.read(archive))
        let bytes = try Data(contentsOf: archive)
        // Same valid ZIP bytes at the same path, but a different filesystem object.
        try FileManager.default.removeItem(at: archive)
        try bytes.write(to: archive, options: .atomic)
        XCTAssertFalse(version.matches(archive))
        let retries = LockedCalls()
        await DownloadsWatcher.unzip(archive, expectedVersion: version, onDeferred: { _ = retries.increment() })
        XCTAssertEqual(retries.count, 1, "a replaced queued archive asks the watcher to settle it again")
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "payload.txt").path))
    }

    func testArchiveChangedDuringExtractionIsPreservedWithoutPublishing() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try makeArchive(in: folder)
        let version = try XCTUnwrap(FileVersion.read(archive))
        let calls = LockedCalls()
        let replacement = Data("new download at the same name".utf8)
        await DownloadsWatcher.unzip(archive, expectedVersion: version, shouldContinue: {
            if calls.increment() == 3 {
                XCTAssertFalse(Thread.isMainThread)
                do { try replacement.write(to: archive, options: .atomic) }
                catch { XCTFail("Could not replace fixture: \(error)") }
            }
            return true
        })
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(try Data(contentsOf: archive), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "payload.txt").path))
    }

    func testFileVersionDetectsWritesAndReplacement() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "invite.ics")
        try Data("first".utf8).write(to: file)
        let version = try XCTUnwrap(FileVersion.read(file))
        XCTAssertTrue(version.matches(file))
        try Data("changed".utf8).write(to: file)
        XCTAssertFalse(version.matches(file))
        let changed = try XCTUnwrap(FileVersion.read(file))
        try Data("changed".utf8).write(to: file, options: .atomic)
        XCTAssertFalse(changed.matches(file))
    }

    func testUnreadableArchiveTreeFailsValidation() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertTrue(DownloadsWatcher.containsEscapingSymlink(in: missing))
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func makeArchive(in folder: URL) throws -> URL {
        let source = folder.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appending(path: "payload.txt"))
        let archive = folder.appending(path: "Original.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", archive.path, "payload.txt"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "file-worker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() -> Int { lock.withLock { value += 1; return value } }
    func decrement() { lock.withLock { value -= 1 } }
}
