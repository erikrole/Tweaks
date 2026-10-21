import Darwin
import XCTest
@testable import Tweaks

final class EthernetHardeningTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ethernet-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingStateNeedsNoRestore() {
        let loaded = EthernetHandoffSavedState.load(from: directory.appending(path: "state.json"))
        XCTAssertFalse(loaded.state.wifiRestoreNeeded)
        XCTAssertFalse(loaded.damaged)
    }

    func testCorruptStateIsTreatedAsPendingRestore() throws {
        let url = directory.appending(path: "state.json")
        try Data("{\"wifiRestoreNee".utf8).write(to: url)
        let loaded = EthernetHandoffSavedState.load(from: url)
        XCTAssertTrue(loaded.state.wifiRestoreNeeded, "a truncated file must not leave Wi-Fi off")
        XCTAssertTrue(loaded.damaged)
    }

    func testOlderStateWithoutAttemptKeyStillDecodes() throws {
        let url = directory.appending(path: "state.json")
        try Data("{\"wifiRestoreNeeded\":true,\"lastAttempt\":12}".utf8).write(to: url)
        let loaded = EthernetHandoffSavedState.load(from: url)
        XCTAssertFalse(loaded.damaged)
        XCTAssertTrue(loaded.state.wifiRestoreNeeded)
        XCTAssertEqual(loaded.state.lastAttempt, 12)
        XCTAssertNil(loaded.state.lastAttemptKey)
    }

    func testUSBTetheringIsNotWiredEthernet() {
        XCTAssertFalse(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en9", displayName: "iPhone USB"))
        XCTAssertFalse(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en9", displayName: "iPad USB"))
        XCTAssertFalse(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en9", displayName: "Android RNDIS"))
        XCTAssertTrue(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en11", displayName: "USB 10/100/1000 LAN"))
        XCTAssertTrue(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en8", displayName: "Thunderbolt Ethernet Slot 1"))
        XCTAssertTrue(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en12", displayName: "CalDigit TS5 Plus"))
    }
}

final class ShareHelperIdentityTests: XCTestCase {
    private func ownStart() -> (UInt64, UInt64) {
        var info = proc_bsdinfo()
        _ = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    func testSameProcessHasNotExited() {
        let (seconds, micros) = ownStart()
        XCTAssertFalse(ShareHelperRecovery.hasExited(.init(pid: getpid(), startedSeconds: seconds, startedMicroseconds: micros)))
    }

    func testReusedPIDCountsAsExited() {
        let (seconds, micros) = ownStart()
        let earlier = ShareHelperIdentity(pid: getpid(), startedSeconds: seconds &- 1, startedMicroseconds: micros)
        XCTAssertTrue(ShareHelperRecovery.hasExited(earlier), "a different start time is a different process")
    }

    func testGoneProcessCountsAsExited() {
        XCTAssertTrue(ShareHelperRecovery.hasExited(.init(pid: 99_999_999, startedSeconds: 1, startedMicroseconds: 0)))
    }
}

@MainActor
final class ShareRetryCoalescingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain = ""

    override func setUp() async throws {
        domain = "ShareRetryCoalescingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    /// Network changes during a mount ask for another pass; they must not cancel the
    /// mount in flight or start overlapping attempts.
    func testNetworkChangesDuringMountDoNotCancelOrStack() async throws {
        let url = URL(string: "smb://example.invalid/a")!
        let entered = expectation(description: "mount entered")
        var mounts = 0
        var finish: CheckedContinuation<Bool, Never>?
        let queue = ShareRemountQueue(defaults: defaults, mounted: { [] }, reachable: { _ in true }, mount: { _ in
            mounts += 1
            return await withCheckedContinuation { continuation in finish = continuation; entered.fulfill() }
        }, wait: { _ in await Task.yield(); try Task.checkCancellation() }, watchConnectivity: false)
        defer { queue.suspend() }
        queue.enqueue([url]); queue.resume()
        await fulfillment(of: [entered], timeout: 3)
        for _ in 0..<5 { queue.retryNow() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(mounts, 1, "no overlapping attempts while one is in flight")
        finish?.resume(returning: true)
        for _ in 0..<50 { await Task.yield(); if queue.pending.isEmpty { break } }
        XCTAssertTrue(queue.pending.isEmpty, "the in-flight mount was allowed to finish and count")
    }
}

final class OpenFilesBoundTests: XCTestCase {
    func testSlowLookupFallsBackSafely() {
        let start = Date()
        let answer = OpenFiles.bounded(fallback: true, timeout: 0.2) { Thread.sleep(forTimeInterval: 0.6); return false }
        XCTAssertTrue(answer, "a lookup that doesn't answer in time counts as open")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        Thread.sleep(forTimeInterval: 0.6) // let the stuck lookup finish so it doesn't count against others
    }

    func testPromptLookupReturnsItsAnswer() {
        XCTAssertFalse(OpenFiles.bounded(fallback: true, timeout: 2) { false })
    }
}

final class ShareChannelTests: XCTestCase {
    /// Trimmed from `smbutil multichannel` on 2026-10-21 (CalDigit TS5 Plus, VPN up).
    private let sample = """
    M     249  utun0  (tunnel  )   29             8 (RSS_0)  [session inactive     ]   10.131.62.40              445    990.0 Mb
    ALT   250  en8    (Ethernet)   28             9 (RSS_0)  [session active       ]   10.131.62.33              445    10.0 Gb
    ALT   252  en0    (wifi    )   16             9 (RSS_2)  [attempting to connect]   10.131.62.33              445    240.3 Mb
    Client NIC:
    \tname: en8, idx: 28, type: wired, speed 10.0 Gb, state connected
    Client NIC:
    \tname: utun0, idx: 29, type: tunnel, speed 990.0 Mb, state connected
    """

    func testActiveChannelIsWiredEthernet() {
        XCTAssertEqual(ShareChannels.active(sample), [.init(interface: "en8", kind: "Ethernet", speed: "10.0 Gb")])
        XCTAssertTrue(ShareChannels.wiredAvailable(sample))
    }

    func testTunnelOnlySessionIsNotEthernet() {
        let tunnelOnly = sample.replacingOccurrences(of: "[session inactive     ]", with: "[session active       ]")
            .replacingOccurrences(of: "(Ethernet)   28             9 (RSS_0)  [session active       ]",
                                  with: "(Ethernet)   28             9 (RSS_0)  [session inactive     ]")
        let channels = ShareChannels.active(tunnelOnly)
        XCTAssertEqual(channels.map(\.interface), ["utun0"])
        XCTAssertFalse(channels.contains { $0.kind == "Ethernet" })
    }
}
