import XCTest
import SystemConfiguration
@testable import Tweaks

private final class FakeShareBackend: ShareMountBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Int32) -> Void)?
    private var callbackQueue: DispatchQueue?
    private var counts = (starts: 0, cancels: 0)
    let startStatus: Int32
    let cancellationAccepted: Bool
    init(startStatus: Int32 = 0, cancellationAccepted: Bool = true) {
        self.startStatus = startStatus; self.cancellationAccepted = cancellationAccepted
    }
    func start(_ url: URL, at directory: URL?, queue: DispatchQueue, completion: @escaping @Sendable (Int32) -> Void) -> Int32 {
        lock.lock(); defer { lock.unlock() }; counts.starts += 1; callback = completion; callbackQueue = queue; return startStatus
    }
    func cancel() -> Bool { lock.lock(); counts.cancels += 1; lock.unlock(); return cancellationAccepted }
    /// Delivered on the attempt's queue, as NetFS does.
    func complete(_ status: Int32) {
        lock.lock(); let callback = callback, queue = callbackQueue; lock.unlock()
        guard let callback, let queue else { return }
        queue.async { callback(status) }
    }
    var starts: Int { lock.lock(); defer { lock.unlock() }; return counts.starts }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return counts.cancels }
}

private final class ShareTestState: @unchecked Sendable {
    private let lock = NSLock()
    var shares: [NetworkShares.Share] = []
    var attempts = 0
    var resets = 0
    var savedReset: TimeInterval = 0
    var continuation: CheckedContinuation<ShareMountResult, Never>?
    func withLock<T>(_ action: (ShareTestState) -> T) -> T { lock.lock(); defer { lock.unlock() }; return action(self) }
}

@MainActor
final class ShareConnectionRecoveryTests: XCTestCase {
    func testConnectivityContextLifetimeCallbacksRunOnBackgroundQueue() async throws {
        var box: ShareConnectivityContext? = ShareConnectivityContext { XCTFail("Lifetime callbacks must not deliver changes") }
        weak var weakBox = box
        let retained = try await Task.detached { [owned = box!] in
            XCTAssertFalse(Thread.isMainThread)
            let context = owned.makeContext()
            let retain = try XCTUnwrap(context.retain)
            return UInt(bitPattern: retain(try XCTUnwrap(context.info)))
        }.value
        box = nil
        XCTAssertNotNil(weakBox, "The C context must own its retained box")
        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            let raw = UnsafeRawPointer(bitPattern: retained)!
            let context = Unmanaged<ShareConnectivityContext>.fromOpaque(raw).takeUnretainedValue().makeContext()
            try XCTUnwrap(context.release)(raw)
        }.value
        XCTAssertNil(weakBox, "Background release must balance the context retain")
    }

    func testConnectivityNotificationHopsToMainActorWithoutRetainingOwner() async throws {
        var owner: ShareConnectivityWatcher? = ShareConnectivityWatcher { XCTFail("Watcher must not start services") }
        weak var weakOwner = owner
        let delivered = expectation(description: "Main actor notification")
        let box = ShareConnectivityContext { [weak owner] in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(owner)
            delivered.fulfill()
        }
        owner = nil
        XCTAssertNil(weakOwner)
        await Task.detached { [box] in
            // No dynamic-store subscription, network change, or mount is needed.
            let store = SCDynamicStoreCreate(nil, "Tweaks.context-regression" as CFString, nil, nil)!
            shareConnectivityNotify(store, [] as CFArray, box.makeContext().info)
        }.value
        await fulfillment(of: [delivered], timeout: 2)
    }
    private let url = URL(string: "smb://nas.example.edu/users")!
    private var share: NetworkShares.Share { .init(mountPoint: URL(filePath: "/Volumes/users"), serverURL: url) }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("condition did not finish")
    }

    func testMountTimeoutCancelsWithoutWaitingForCallbackAndIgnoresLateCompletion() async throws {
        let backend = FakeShareBackend()
        let attempt = ShareMountAttempt(backend: backend, timeout: 0.02)
        let result = await attempt.run(url, at: nil)
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(backend.cancels, 1)
        backend.complete(0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(backend.cancels, 1)
    }

    func testCancellationOwnsCompletionEvenWhenNetFSNeverCallsBack() async throws {
        let backend = FakeShareBackend()
        let attempt = ShareMountAttempt(backend: backend, timeout: 10)
        let task = Task { await attempt.run(url, at: nil) }
        try await waitFor { backend.starts == 1 }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(backend.cancels, 1)
        backend.complete(0)
    }

    func testRejectedCancellationQuarantinesOtherMountsUntilTerminalCallback() async throws {
        let safety = ShareMountSafety()
        let lease = try XCTUnwrap(safety.begin())
        let request = try XCTUnwrap(safety.beginRequest(lease))
        let backend = FakeShareBackend(cancellationAccepted: false)
        let attempt = ShareMountAttempt(backend: backend, timeout: 0.02) {
            safety.finishRequest(lease, request: request)
        }
        let result = await attempt.run(url, at: nil)
        XCTAssertEqual(result, .cancellationUnconfirmed)
        safety.end(lease)
        XCTAssertNil(safety.begin(), "a rejected cancellation must retain global ownership")
        backend.complete(0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(safety.begin(), "a terminal callback releases quarantine")
    }

    func testImmediateFailureDoesNotLeaveTheMountSlotWaitingForCallback() async {
        let backend = FakeShareBackend(startStatus: EAUTH)
        let result = await ShareMountAttempt(backend: backend, timeout: 10).run(url, at: nil)
        XCTAssertEqual(result, .failed(EAUTH))
        XCTAssertEqual(backend.cancels, 0)
    }

    func testSuccessfulMountCancelsDeadline() async throws {
        let backend = FakeShareBackend()
        let attempt = ShareMountAttempt(backend: backend, timeout: 0.1)
        let task = Task { await attempt.run(url, at: nil) }
        try await waitFor { backend.starts == 1 }
        backend.complete(0)
        let result = await task.value
        XCTAssertEqual(result, .mounted)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(backend.cancels, 0)
    }

    func testKnownHelperHangRequiresBothSMBAccountLookupAndBlockedMainThread() {
        let frames = """
            10 Thread_1 DispatchQueue_1: com.apple.main-thread (serial)
            + 10 objc_sync_enter
            + 10 _os_unfair_lock_lock_slow
            + 10 __ulock_wait2
            10 Thread_2
            + 10 netfs_Mount
            + 10 SMB_Mount
            + 10 GetNetworkAccountSID
            + 10 LsarGetUserName
            + 10 rpc__cn_call_transceive
            + 10 rpc__cn_assoc_receive_frag
            + 10 __psynch_cvwait
        """.replacingOccurrences(of: "+", with: " ")
        XCTAssertTrue(ShareHelperRecovery.knownHang(frames))
        XCTAssertFalse(ShareHelperRecovery.knownHang(frames.replacingOccurrences(of: "LsarGetUserName", with: "")))
        XCTAssertFalse(ShareHelperRecovery.knownHang(frames.replacingOccurrences(of: "__ulock_wait2", with: "")))
        XCTAssertFalse(ShareHelperRecovery.knownHang("SMB_Mount GetNetworkAccountSID LsarGetUserName rpc__cn_call_transceive __psynch_cvwait __ulock_wait2"))
        XCTAssertFalse(ShareHelperRecovery.knownHang(frames + "\n            10 Thread_3\n                netfs_Mount"))
        // As sampled live on 2026-10-21: a second retry stuck just above LsarGetUserName.
        let secondRetry = """

            10 Thread_3
            + 10 netfs_Mount
            + 10 SMB_Mount
            + 10 GetNetworkAccountSID
            + 10 rpc__cn_call_transceive
            + 10 rpc__cn_assoc_receive_frag
            + 10 __psynch_cvwait
        """.replacingOccurrences(of: "+", with: " ")
        XCTAssertTrue(ShareHelperRecovery.knownHang(frames + secondRetry))
        XCTAssertFalse(ShareHelperRecovery.knownHang(frames.replacingOccurrences(of: "LsarGetUserName", with: "") + secondRetry),
                       "at least one mount thread must show the account lookup")

    }

    func testResetGateFailsClosedOnUnknownMountsMountedSharesSleepAndStaleLease() throws {
        let safety = ShareMountSafety()
        let lease = try XCTUnwrap(safety.begin())
        var signals = 0
        XCTAssertFalse(safety.withResetPermission(lease, mounted: { nil }, signal: { signals += 1; return true }))
        XCTAssertFalse(safety.withResetPermission(lease, mounted: { [share] }, signal: { signals += 1; return true }))
        safety.beginUnmount()
        XCTAssertFalse(safety.withResetPermission(lease, mounted: { [] }, signal: { signals += 1; return true }))
        safety.endUnmount(); safety.invalidate()
        XCTAssertFalse(safety.withResetPermission(lease, mounted: { [] }, signal: { signals += 1; return true }))
        safety.end(lease)
        safety.setSleeping(true)
        XCTAssertNil(safety.begin())
        safety.setSleeping(false)
        let current = try XCTUnwrap(safety.begin())
        XCTAssertTrue(safety.withResetPermission(current, mounted: { [] }, signal: { signals += 1; return true }))
        XCTAssertEqual(signals, 1)
    }

    func testTimeoutRecoversOnceAndVerifiesMountTable() async {
        let state = ShareTestState(), share = share
        let mounter = ShareMounter(safety: ShareMountSafety(), mounted: { state.withLock { $0.shares } }, attempt: { _, _, terminal in
            defer { terminal() }
            return state.withLock { state in
                state.attempts += 1
                if state.attempts == 1 { return .timedOut }
                state.shares = [share]; return .mounted
            }
        }, recover: { _ in state.withLock { $0.resets += 1 }; return true }, directory: { _ in nil }, reachable: { _ in true },
           clock: { 1000 }, resetDate: { 0 }, saveResetDate: { value in state.withLock { $0.savedReset = value } }, log: { _ in })
        let result = await mounter.mount(url)
        XCTAssertTrue(result)
        XCTAssertEqual(state.withLock { $0.attempts }, 2)
        XCTAssertEqual(state.withLock { $0.resets }, 1)
        XCTAssertEqual(state.withLock { $0.savedReset }, 1000)
    }

    func testDifferentSharesCannotOverlapMountOrRecovery() async throws {
        let state = ShareTestState()
        let mounter = ShareMounter(safety: ShareMountSafety(), mounted: { [] }, attempt: { _, _, terminal in
            defer { terminal() }
            return await withCheckedContinuation { continuation in state.withLock { $0.continuation = continuation; $0.attempts += 1 } }
        }, recover: { _ in state.withLock { $0.resets += 1 }; return false }, directory: { _ in nil }, reachable: { _ in false },
           clock: { 1000 }, resetDate: { 0 }, saveResetDate: { _ in }, log: { _ in })
        let first = Task { await mounter.mount(url) }
        try await waitFor { state.withLock { $0.attempts == 1 } }
        let second = await mounter.mount(URL(string: "smb://other.example.edu/media")!)
        XCTAssertFalse(second)
        first.cancel()
        state.withLock { $0.continuation }?.resume(returning: .timedOut)
        let result = await first.value
        XCTAssertFalse(result)
        XCTAssertEqual(state.withLock { $0.attempts }, 1)
        XCTAssertEqual(state.withLock { $0.resets }, 0)
    }

    func testFailureCooldownAndExistingMountProtectAgainstRepeatedAttempts() async {
        let state = ShareTestState(), share = share
        let mounter = ShareMounter(safety: ShareMountSafety(), mounted: { state.withLock { $0.shares } }, attempt: { _, _, terminal in
            defer { terminal() }
            state.withLock { $0.attempts += 1 }; return .failed(EAUTH)
        }, recover: { _ in XCTFail("authentication failure must not reset helper"); return false }, directory: { _ in nil },
           clock: { 1000 }, resetDate: { 0 }, saveResetDate: { _ in }, log: { _ in })
        let first = await mounter.mount(url), second = await mounter.mount(url)
        XCTAssertFalse(first); XCTAssertFalse(second)
        XCTAssertEqual(state.withLock { $0.attempts }, 1)
        state.withLock { $0.shares = [share] }
        let existing = await mounter.mount(url)
        XCTAssertTrue(existing)
        XCTAssertEqual(state.withLock { $0.attempts }, 1)
    }

    func testLaterNetworkCheckCanRecoverAQuarantinedRequest() async {
        let state = ShareTestState(), share = share
        let mounter = ShareMounter(safety: ShareMountSafety(), mounted: { state.withLock { $0.shares } }, attempt: { _, _, terminal in
            let number = state.withLock { $0.attempts += 1; return $0.attempts }
            if number == 1 { return .cancellationUnconfirmed }
            state.withLock { $0.shares = [share] }; terminal(); return .mounted
        }, recover: { _ in state.withLock { $0.resets += 1; return $0.resets > 1 } }, directory: { _ in nil }, reachable: { _ in true },
           clock: { 1000 }, resetDate: { 0 }, saveResetDate: { _ in }, log: { _ in })
        let first = await mounter.mount(url)
        XCTAssertFalse(first)
        let second = await mounter.mount(url)
        XCTAssertTrue(second)
        XCTAssertEqual(state.withLock { $0.attempts }, 2)
        XCTAssertEqual(state.withLock { $0.resets }, 2)
    }

    func testOriginalMountReservationIsReusedButLinksAndDataArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-mount-\(UUID().uuidString)")
        let target = root.appendingPathComponent("users")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { chmod(target.path, 0o700); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(target.path, 0o111), 0)
        XCTAssertEqual(ShareMountDirectory.preferred(for: url, root: root)?.path, target.path)
        var info = stat(); XCTAssertEqual(lstat(target.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o111)
        chmod(target.path, 0o700)
        try Data("preserve".utf8).write(to: target.appendingPathComponent("file"))
        chmod(target.path, 0o111)
        XCTAssertNil(ShareMountDirectory.preferred(for: url, root: root))
        chmod(target.path, 0o700)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file"), encoding: .utf8), "preserve")
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("original"))
        XCTAssertNil(ShareMountDirectory.preferred(for: url, root: root))
    }

    func testNetworkRetryWaitsForVPNAndCoalescesChangesDuringMount() async throws {
        var ready = false, mounted = false, attempts = 0, waits = 0
        var pending: CheckedContinuation<Bool, Never>?
        let connector = ShareAutoConnect(mounted: { mounted ? [self.url] : [] }, reachable: { _ in ready }, mount: { _ in
            attempts += 1
            return await withCheckedContinuation { pending = $0 }
        }, wait: { delay in
            waits += 1
            if delay > 0 { ready = true }
        }, watchConnectivity: false)
        connector.shares = [url]; connector.start()
        try await waitFor { attempts == 1 }
        for _ in 0..<20 { connector.networkChanged() }
        mounted = true; pending?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(attempts, 1)
        XCTAssertGreaterThanOrEqual(waits, 2)
        connector.stop()
    }

    func testDisabledConnectorDoesNotMountWhenReachabilityCompletesLate() async throws {
        var continuation: CheckedContinuation<Bool, Never>?, mounts = 0
        let connector = ShareAutoConnect(mounted: { [] }, reachable: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, mount: { _ in mounts += 1; return true }, wait: { _ in }, watchConnectivity: false)
        connector.shares = [url]; connector.start()
        try await waitFor { continuation != nil }
        connector.stop(); continuation?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(mounts, 0)
    }
}
