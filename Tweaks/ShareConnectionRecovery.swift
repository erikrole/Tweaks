import AppKit
import Darwin
import Foundation
import NetFS
import Network
import SystemConfiguration
import os

enum ShareMountResult: Equatable, Sendable {
    case mounted, failed(Int32), timedOut, cancelled, cancellationUnconfirmed
}

protocol ShareMountBackend: Sendable {
    /// `completion` must run on `queue`, the attempt's serial queue, so a finished request
    /// can never be cancelled after NetFS has released it.
    func start(_ url: URL, at directory: URL?, queue: DispatchQueue, completion: @escaping @Sendable (Int32) -> Void) -> Int32
    func cancel() -> Bool
}

/// NetFS calls and its request pointer are confined to ShareMountAttempt's queue.
final class NativeShareMountBackend: ShareMountBackend, @unchecked Sendable {
    private var request: AsyncRequestID?

    func start(_ url: URL, at directory: URL?, queue: DispatchQueue, completion: @escaping @Sendable (Int32) -> Void) -> Int32 {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOptions = NSMutableDictionary()
        if directory != nil { mountOptions[kNetFSMountAtMountDirKey] = true }
        return Int32(NetFSMountURLAsync(url as CFURL, directory as CFURL?, nil, nil,
            openOptions, mountOptions, &request, queue) { [self] status, _, _ in
                request = nil // finished; NetFS owns and frees it now
                completion(Int32(status))
            })
    }

    func cancel() -> Bool {
        guard let request else { return true }
        let status = NetFSMountURLCancel(request)
        if status == 0 { self.request = nil }
        return status == 0
    }
}

/// Cancellation does not produce a NetFS callback. Own the continuation ourselves,
/// including cancellation before start, timeouts, and callbacks arriving afterward.
final class ShareMountAttempt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Tweaks.share-mount", qos: .utility)
    private let backend: any ShareMountBackend
    private let timeout: TimeInterval
    private let terminal: @Sendable () -> Void
    private var continuation: CheckedContinuation<ShareMountResult, Never>?
    private var deadline: DispatchWorkItem?
    private var ended = false

    init(backend: any ShareMountBackend = NativeShareMountBackend(), timeout: TimeInterval = 25,
         terminal: @escaping @Sendable () -> Void = {}) {
        self.backend = backend; self.timeout = timeout; self.terminal = terminal
    }

    func run(_ url: URL, at directory: URL?) async -> ShareMountResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !ended else { continuation.resume(returning: .cancelled); return }
                    self.continuation = continuation
                    let status = backend.start(url, at: directory, queue: queue) { [self] status in
                        finish(status == 0 || status == EEXIST ? .mounted : .failed(status))
                    }
                    if status != 0 { finish(.failed(status)); return }
                    let work = DispatchWorkItem { [self] in finish(.timedOut, cancel: true) }
                    deadline = work
                    queue.asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.cancelled, cancel: true) }
        }
    }

    private func finish(_ result: ShareMountResult, cancel: Bool = false) {
        guard !ended else {
            if !cancel { terminal() } // A rejected cancellation may still complete later.
            return
        }
        ended = true
        deadline?.cancel(); deadline = nil
        let confirmed = !cancel || backend.cancel()
        if confirmed { terminal() }
        continuation?.resume(returning: confirmed ? result : .cancellationUnconfirmed); continuation = nil
    }
}

/// One synchronous gate coordinates mount ownership, sleep, unmounts, and the final
/// helper signal. Unknown mount-table state never authorizes recovery.
final class ShareMountSafety: @unchecked Sendable {
    struct Lease: Equatable, Sendable { let id: UUID; let epoch: UInt64 }
    static let shared = ShareMountSafety()
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var owner: Lease?
    private var request: UUID?
    private var releaseRequested = false
    private var sleeping = false
    private var unmounts = 0

    func begin() -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil, !sleeping, unmounts == 0 else { return nil }
        let lease = Lease(id: UUID(), epoch: epoch)
        owner = lease; releaseRequested = false; return lease
    }
    func end(_ lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard owner == lease else { return }
        releaseRequested = true
        if request == nil { owner = nil }
    }
    func beginRequest(_ lease: Lease) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard owner == lease, epoch == lease.epoch, !sleeping, unmounts == 0, request == nil else { return nil }
        let id = UUID(); request = id; return id
    }
    func finishRequest(_ lease: Lease, request id: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard owner?.id == lease.id, id == nil || request == id else { return }
        request = nil
        if releaseRequested { owner = nil }
    }
    func outstanding(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return owner?.id == lease.id && request != nil
    }
    /// Only a fresh authorized caller may adopt a quarantined request after a
    /// network change. The request ID stays unchanged for its eventual callback.
    func adopt(_ lease: Lease) -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard owner?.id == lease.id, request != nil, releaseRequested, !sleeping, unmounts == 0 else { return nil }
        let renewed = Lease(id: lease.id, epoch: epoch)
        owner = renewed; releaseRequested = false; return renewed
    }
    func invalidate() { lock.lock(); epoch &+= 1; lock.unlock() }
    func setSleeping(_ value: Bool) { lock.lock(); sleeping = value; epoch &+= 1; lock.unlock() }
    func beginUnmount() { lock.lock(); unmounts += 1; epoch &+= 1; lock.unlock() }
    func endUnmount() { lock.lock(); unmounts = max(0, unmounts - 1); lock.unlock() }
    func isCurrent(_ lease: Lease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return owner == lease && epoch == lease.epoch && !sleeping && unmounts == 0
    }
    func withResetPermission(_ lease: Lease, mounted: () -> [NetworkShares.Share]?, signal: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == lease, epoch == lease.epoch, !sleeping, unmounts == 0,
              let shares = mounted(), shares.isEmpty else { return false }
        return signal()
    }
}

enum ShareMountDirectory {
    /// Reuse only macOS's empty, owned, local 0111 mount reservation. Never delete,
    /// rename, follow a symlink, or cover a folder containing user data.
    static func preferred(for url: URL, root: URL = URL(filePath: "/Volumes")) -> URL? {
        guard let name = url.path(percentEncoded: false).split(separator: "/").first.map(String.init),
              !name.isEmpty, name != ".", name != "..", !name.contains(":"), !name.contains("\\"),
              !name.contains("\0") else { return nil }
        let target = root.appendingPathComponent(name)
        let fd = open(target.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat(), fs = statfs()
        guard fstat(fd, &info) == 0, fstatfs(fd, &fs) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o111, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              NetworkShares.snapshot()?.contains(where: { $0.mountPoint.path == target.path }) == false,
              fchmod(fd, 0o511) == 0 else { return nil }
        defer {
            var current = stat()
            if fstat(fd, &current) == 0, current.st_mode & 0o7777 == 0o511 { _ = fchmod(fd, 0o111) }
        }
        let readFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard readFD >= 0 else { return nil }
        guard let directory = fdopendir(readFD) else { close(readFD); return nil }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else { if errno != 0 { return nil }; break }
            let entryName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if entryName != "." && entryName != ".." { return nil }
        }
        var pathInfo = stat()
        guard lstat(target.path, &pathInfo) == 0, pathInfo.st_dev == info.st_dev,
              pathInfo.st_ino == info.st_ino, pathInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        return target
    }
}

struct ShareHelperIdentity: Equatable, Sendable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
}

enum ShareRecoveryLog {
    static let queue = DispatchQueue(label: "Tweaks.share-log", qos: .utility)
    static func write(_ message: String) {
        Logger(subsystem: "com.erole.Tweaks", category: "ShareRecovery").info("\(message, privacy: .public)")
        queue.async {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.erole.Tweaks/ShareRecovery")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("events.log")
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 131_072 {
                let old = root.appendingPathComponent("events.previous.log")
                try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: url, to: old)
            }
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let file = try? FileHandle(forWritingTo: url) {
                _ = try? file.seekToEnd()
                try? file.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
                try? file.close()
            }
        }
    }
}

enum ShareHelperRecovery {
    static let executable = "/System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthSysAgent"

    static func identity(_ pid: Int32) -> ShareHelperIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable else { return nil }
        return .init(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    static func currentIdentity() -> ShareHelperIdentity? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard actual > 0, actual <= pids.count else { return nil }
        let helpers = pids.prefix(Int(actual)).compactMap(identity)
        return helpers.count == 1 ? helpers.first : nil
    }
    /// Gone, or the PID now belongs to a different process (any user or executable).
    static func hasExited(_ helper: ShareHelperIdentity) -> Bool {
        if kill(helper.pid, 0) == -1, errno == ESRCH { return true }
        var info = proc_bsdinfo()
        guard proc_pidinfo(helper.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size
        else { return true } // not readable as ours any more
        return info.pbi_start_tvsec != helper.startedSeconds || info.pbi_start_tvusec != helper.startedMicroseconds
    }

    static func knownHang(_ sample: String) -> Bool {
        var threads: [String] = [], current: [String] = []
        for line in sample.components(separatedBy: "\n") {
            if line.range(of: #"^\s+\d+ Thread_\d+"#, options: .regularExpression) != nil {
                if !current.isEmpty { threads.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty { current.append(line) }
        }
        if !current.isEmpty { threads.append(current.joined(separator: "\n")) }
        func ordered(_ frames: [String], in thread: String) -> Bool {
            var remaining = thread[...]
            for frame in frames {
                guard let match = remaining.range(of: frame) else { return false }
                remaining = remaining[match.upperBound...]
            }
            return true
        }
        let mains = threads.filter { $0.components(separatedBy: "\n").first?.contains("com.apple.main-thread") == true }
        let mounts = threads.filter { $0.contains("netfs_Mount") }
        guard mains.count == 1, !mounts.isEmpty, mounts.count <= 8 else { return false }
        // Each retry adds another mount thread stuck in the same account lookup, sometimes
        // inside LsarGetUserName and sometimes just above it. Every mount thread must be
        // stuck in that RPC, and at least one must show LsarGetUserName.
        let stuckInLookup = ["netfs_Mount", "SMB_Mount", "GetNetworkAccountSID",
                             "rpc__cn_call_transceive", "rpc__cn_assoc_receive_frag", "__psynch_cvwait"]
        return ordered(["objc_sync_enter", "_os_unfair_lock_lock_slow", "__ulock_wait"], in: mains[0])
            && mounts.allSatisfy { ordered(stuckInLookup, in: $0) }
            && mounts.contains { ordered(["GetNetworkAccountSID", "LsarGetUserName", "rpc__cn_call_transceive"], in: $0) }
    }

    private static func sample(_ helper: ShareHelperIdentity) -> String? {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Tweaks-share-\(UUID().uuidString).sample")
        _ = FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: path) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sample")
        process.arguments = [String(helper.pid), "1", "10", "-file", path.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + 4) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0,
              let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000 else { return nil }
        return try? String(contentsOf: path, encoding: .utf8)
    }

    private static let sampleQueue = DispatchQueue(label: "Tweaks.share-sample", qos: .utility)

    /// `sample` blocks for seconds; run it off the Swift concurrency pool.
    private static func sampled(_ helper: ShareHelperIdentity) async -> String? {
        await withCheckedContinuation { continuation in
            sampleQueue.async { continuation.resume(returning: sample(helper)) }
        }
    }

    static func recover(_ lease: ShareMountSafety.Lease, safety: ShareMountSafety) async -> Bool {
        await Task.detached(priority: .utility) {
            guard safety.isCurrent(lease), let mounted = NetworkShares.snapshot(), mounted.isEmpty else { return false }
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return false }
            var pids = [Int32](repeating: 0, count: Int(count) + 32)
            let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            guard actual > 0, actual <= pids.count else { return false }
            let helpers = pids.prefix(Int(actual)).compactMap(identity)
            guard helpers.count == 1, let helper = helpers.first,
                  let first = await sampled(helper), knownHang(first), safety.isCurrent(lease) else { return false }
            try? await Task.sleep(for: .milliseconds(500))
            guard identity(helper.pid) == helper, let second = await sampled(helper), knownHang(second) else { return false }
            let signaled = safety.withResetPermission(lease, mounted: NetworkShares.snapshot) {
                guard identity(helper.pid) == helper else { return false }
                return kill(helper.pid, SIGTERM) == 0
            }
            guard signaled else { return false }
            for _ in 0..<30 {
                if hasExited(helper) { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }.value
    }
}

/// Actor reentrancy is additionally gated by a global lease; other share URLs and
/// sleep restores cannot overlap a mount or reset while this method awaits.
actor ShareMounter {
    static let shared = ShareMounter()
    private let safety: ShareMountSafety
    private let mounted: @Sendable () -> [NetworkShares.Share]?
    private let attempt: @Sendable (URL, URL?, @escaping @Sendable () -> Void) async -> ShareMountResult
    private let recover: @Sendable (ShareMountSafety.Lease) async -> Bool
    private let directory: @Sendable (URL) -> URL?
    private let reachable: @Sendable (URL) async -> Bool
    private let clock: @Sendable () -> TimeInterval
    private let resetDate: @Sendable () -> TimeInterval
    private let saveResetDate: @Sendable (TimeInterval) -> Void
    private let log: @Sendable (String) -> Void
    private var cooldown: [URL: TimeInterval] = [:]
    private var quarantine: (url: URL, lease: ShareMountSafety.Lease, helper: ShareHelperIdentity?)?

    init(safety: ShareMountSafety = .shared,
         mounted: @escaping @Sendable () -> [NetworkShares.Share]? = NetworkShares.snapshot,
         attempt: @escaping @Sendable (URL, URL?, @escaping @Sendable () -> Void) async -> ShareMountResult = { url, directory, terminal in
             await ShareMountAttempt(terminal: terminal).run(url, at: directory)
         },
         recover: (@Sendable (ShareMountSafety.Lease) async -> Bool)? = nil,
         directory: @escaping @Sendable (URL) -> URL? = { ShareMountDirectory.preferred(for: $0) },
         reachable: @escaping @Sendable (URL) async -> Bool = NetworkShares.isReachable,
         clock: @escaping @Sendable () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
         resetDate: @escaping @Sendable () -> TimeInterval = { UserDefaults.standard.double(forKey: "lastShareHelperRecovery") },
         saveResetDate: @escaping @Sendable (TimeInterval) -> Void = { UserDefaults.standard.set($0, forKey: "lastShareHelperRecovery") },
         log: @escaping @Sendable (String) -> Void = ShareRecoveryLog.write) {
        self.safety = safety; self.mounted = mounted; self.attempt = attempt
        self.recover = recover ?? { await ShareHelperRecovery.recover($0, safety: safety) }
        self.directory = directory; self.reachable = reachable; self.clock = clock
        self.resetDate = resetDate; self.saveResetDate = saveResetDate; self.log = log
    }

    /// Later enabled checks own quarantine recovery; never silently leave all
    /// future network-change retries blocked behind a rejected cancellation.
    private func revisitQuarantine() async -> Bool {
        guard let pending = quarantine else { return true }
        guard safety.outstanding(pending.lease) else { quarantine = nil; return true }
        if let helper = pending.helper, ShareHelperRecovery.hasExited(helper) {
            safety.finishRequest(pending.lease); quarantine = nil; cooldown[pending.url] = nil; return true
        }
        guard let lease = safety.adopt(pending.lease) else { return false }
        defer { safety.end(lease) }
        quarantine = (pending.url, lease, pending.helper)
        guard !Task.isCancelled, clock() - resetDate() >= 600,
              let shares = mounted(), shares.isEmpty, await reachable(pending.url), safety.isCurrent(lease) else { return false }
        return await withTaskCancellationHandler {
            saveResetDate(clock())
            guard await recover(lease) else { return false }
            // A confirmed helper exit terminates the old request even if a later
            // network event revoked permission for an immediate retry.
            safety.finishRequest(lease); quarantine = nil; cooldown[pending.url] = nil
            log("Quarantined share request recovered after a later network check")
            return !Task.isCancelled
        } onCancel: { safety.invalidate() }
    }

    func mount(_ url: URL) async -> Bool {
        guard !Task.isCancelled, let snapshot = mounted() else { return false }
        if ShareAutoConnect.sharesToMount(wanted: [url], mounted: snapshot.map(\.serverURL)).isEmpty { return true }
        guard await revisitQuarantine(), !Task.isCancelled,
              clock() >= cooldown[url, default: 0], let lease = safety.begin() else { return false }
        var requestHelper: ShareHelperIdentity?
        defer {
            if safety.outstanding(lease) { quarantine = (url, lease, requestHelper ?? ShareHelperRecovery.currentIdentity()) }
            safety.end(lease)
        }
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            log("Starting bounded share connection")
            func runAttempt() async -> ShareMountResult {
                guard let request = safety.beginRequest(lease) else { return .cancelled }
                return await attempt(url, directory(url)) { [safety] in safety.finishRequest(lease, request: request) }
            }
            var result = await runAttempt()
            if result == .cancellationUnconfirmed { requestHelper = ShareHelperRecovery.currentIdentity() }
            if (result == .timedOut || result == .cancellationUnconfirmed), !Task.isCancelled, safety.isCurrent(lease),
               clock() - resetDate() >= 600, let currentMounts = mounted(), currentMounts.isEmpty,
               await reachable(url), safety.isCurrent(lease) {
                log("Mount timed out; checking for the known macOS share-helper hang")
                // Reserve the cooldown before sampling so restart/repeated failures cannot loop.
                saveResetDate(clock())
                if await recover(lease), !Task.isCancelled, safety.isCurrent(lease) {
                    log("Recovered the verified stalled share helper; retrying once")
                    safety.finishRequest(lease) // Old helper/request is confirmed gone.
                    result = await runAttempt()
                } else { log("Helper recovery skipped: safety checks did not qualify") }
            }
            guard !Task.isCancelled else { return false }
            if let snapshot = mounted(), ShareAutoConnect.sharesToMount(wanted: [url], mounted: snapshot.map(\.serverURL)).isEmpty {
                cooldown[url] = nil
                log("Share connected; mount table verified")
                if let share = snapshot.first(where: { ShareAutoConnect.sharesToMount(wanted: [url], mounted: [$0.serverURL]).isEmpty }) {
                    ShareChannels.report(share.mountPoint)
                }
                return true
            }
            if result != .cancelled { cooldown[url] = clock() + 300 }
            if result == .cancellationUnconfirmed {
                log("Share request quarantined; later enabled checks will recheck helper recovery")
            } else { log("Share connection deferred; waiting for network or saved sign-in (\(result))") }
            return false
        } onCancel: { safety.invalidate() }
    }
}

/// VPN route/DNS changes do not always change NWPath. Watch both sources, and wake.
@MainActor
final class ShareConnectivityWatcher {
    private var store: SCDynamicStore?
    private var path: NWPathMonitor?
    private var wake: NSObjectProtocol?
    private var sleep: NSObjectProtocol?
    private let changed: @MainActor () -> Void
    init(changed: @escaping @MainActor () -> Void) { self.changed = changed }

    func start() {
        guard path == nil else { return }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: { raw in
            _ = Unmanaged<ShareConnectivityWatcher>.fromOpaque(raw).retain()
            return raw
        }, release: { raw in
            Unmanaged<ShareConnectivityWatcher>.fromOpaque(raw).release()
        }, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "Tweaks.share-connectivity" as CFString, { _, _, info in
            guard let info else { return }
            MainActor.assumeIsolated {
                let watcher = Unmanaged<ShareConnectivityWatcher>.fromOpaque(info).takeUnretainedValue()
                ShareMountSafety.shared.invalidate(); watcher.changed()
            }
        }, &context)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS"] as CFArray,
                ["State:/Network/Service/.*/IPv[46]", "State:/Network/Service/.*/DNS", "State:/Network/Interface/en[0-9]+/Link"] as CFArray)
            SCDynamicStoreSetDispatchQueue(store, .main)
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.changed() } }
        monitor.start(queue: DispatchQueue(label: "Tweaks.share-path")); path = monitor
        // Gate recovery on sleep here too, so it holds when "unmount before sleep" is off.
        sleep = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShareMountSafety.shared.setSleeping(true) }
        }
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { ShareMountSafety.shared.setSleeping(false); self?.changed() }
        }
    }

    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil; path?.cancel(); path = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }; wake = nil
        if let sleep { NSWorkspace.shared.notificationCenter.removeObserver(sleep) }; sleep = nil
    }
}

/// Which network the share's data actually uses. SMB multichannel binds a channel per
/// client interface, so on a dock the session should be active on wired Ethernet even
/// while a VPN owns the default route. Logged after each connect; a HUD flags a share
/// that lands on the VPN or Wi-Fi only while Ethernet is connected.
enum ShareChannels {
    struct Channel: Equatable, Sendable {
        var interface: String
        var kind: String
        var speed: String
    }

    /// Active channels from `smbutil multichannel -m` output.
    static func active(_ text: String) -> [Channel] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.contains("session active") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count > 4, let open = fields.firstIndex(where: { $0.hasPrefix("(") }) else { return nil }
            let kind = fields[open].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let interface = fields[open - 1]
            let speed = fields.suffix(2).joined(separator: " ")
            return Channel(interface: interface, kind: kind, speed: speed)
        }
    }

    /// True when the client lists a connected wired NIC.
    static func wiredAvailable(_ text: String) -> Bool {
        text.contains("type: wired") && text.components(separatedBy: "Client NIC:").contains {
            $0.contains("type: wired") && $0.contains("state connected")
        }
    }

    private static let queue = DispatchQueue(label: "Tweaks.share-channels", qos: .utility)

    static func report(_ mountPoint: URL) {
        queue.asyncAfter(deadline: .now() + 3) { // channels finish setting up after the mount
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/smbutil")
            process.arguments = ["multichannel", "-m", mountPoint.path(percentEncoded: false)]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            guard (try? process.run()) != nil else { return }
            guard done.wait(timeout: .now() + 5) == .success else {
                process.terminate(); ShareRecoveryLog.write("Share channel check timed out"); return
            }
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let channels = active(text)
            let summary = channels.map { "\($0.interface) (\($0.kind)) \($0.speed)" }.joined(separator: ", ")
            ShareRecoveryLog.write("Share channel: \(summary.isEmpty ? "none active" : summary)")
            if wiredAvailable(text), !channels.contains(where: { $0.kind == "Ethernet" }) {
                ShareRecoveryLog.write("Share is not using wired Ethernet although it is connected")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        HUD.show("NAS isn't using Ethernet · check the dock", symbol: "cable.connector", duration: 4)
                    }
                }
            }
        }
    }
}
