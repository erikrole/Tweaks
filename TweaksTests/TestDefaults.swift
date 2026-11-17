import Darwin
import Foundation
import XCTest

/// Throwaway `UserDefaults` suites for tests that leave nothing in `~/Library/Preferences`.
///
/// A suite named `Foo-<UUID>` lives in `~/Library/Preferences/Foo-<UUID>.plist`, and cfprefsd
/// writes that file back (empty) when the test process exits, even after
/// `removePersistentDomain(forName:)` and deleting it. Every run used to leave ~50 of them.
/// CFPreferences stores a suite whose name is an absolute path at that path instead, so test
/// suites live under `$TMPDIR/TweaksTestDefaults/pid-<pid>/`. Folders of test processes that
/// have exited are removed the first time a suite is made, once cfprefsd is done with them.
enum TestDefaults {
    static let root = FileManager.default.temporaryDirectory.appending(path: "TweaksTestDefaults")

    static let directory: URL = {
        pruneExitedRuns()
        let directory = root.appending(path: "pid-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Removes the folders of test processes that have exited.
    static func pruneExitedRuns() {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries where entry.hasPrefix("pid-") {
            guard let pid = Int32(entry.dropFirst(4)), !isRunning(pid) else { continue }
            try? fileManager.removeItem(at: root.appending(path: entry))
        }
    }

    /// A unique suite name: an absolute path inside this process's folder.
    static func domain(_ prefix: String) -> String {
        directory.appending(path: "\(prefix)-\(UUID().uuidString)").path
    }

    static func remove(_ domain: String) {
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

extension XCTestCase {
    /// A fresh suite that is emptied when the test ends.
    func makeTestDefaults(_ prefix: String) -> UserDefaults {
        let domain = TestDefaults.domain(prefix)
        addTeardownBlock { TestDefaults.remove(domain) }
        return UserDefaults(suiteName: domain)!
    }
}

final class TestDefaultsTests: XCTestCase {
    func testSuitesPersistOutsideUserPreferences() {
        let domain = TestDefaults.domain("TweaksTestDefaults")
        defer { TestDefaults.remove(domain) }
        UserDefaults(suiteName: domain)!.set(true, forKey: "written")
        XCTAssertTrue(UserDefaults(suiteName: domain)!.bool(forKey: "written"), "a second instance reads the same suite")

        let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences").path
        XCTAssertFalse(domain.hasPrefix(preferences))
        XCTAssertTrue(domain.hasPrefix(TestDefaults.directory.path))

        TestDefaults.remove(domain)
        XCTAssertNil(UserDefaults(suiteName: domain)!.object(forKey: "written"))
    }

    func testFoldersOfExitedTestRunsAreRemoved() throws {
        let fileManager = FileManager.default
        let mine = TestDefaults.directory
        // macOS pids stay below 99999, so this folder can only belong to an exited run.
        XCTAssertEqual(kill(99_999, 0), -1)
        let stale = TestDefaults.root.appending(path: "pid-99999")
        try fileManager.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data().write(to: stale.appending(path: "Leftover.plist"))

        TestDefaults.pruneExitedRuns()

        XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
        XCTAssertTrue(fileManager.fileExists(atPath: mine.path), "the running process keeps its folder")
    }
}
