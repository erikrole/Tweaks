import AppKit
import Foundation
import NetFS
import Network

// MARK: - Network shares

/// Mounted network shares (SMB, AFP, NFS, WebDAV) and their server URLs.
enum NetworkShares {
    struct Share: Equatable, Sendable {
        let mountPoint: URL
        /// "smb://nas.example.edu/users", without the user name.
        let serverURL: URL
    }

    static func mounted() -> [Share] { snapshot() ?? [] }

    static func snapshot() -> [Share]? {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        defer { if let mounts { free(mounts) } }
        guard count > 0, let mounts else { return nil }
        var shares: [Share] = []
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let type = withUnsafePointer(to: &entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let from = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let onPath = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if let url = serverURL(type: type, mountedFrom: from) {
                shares.append(Share(mountPoint: URL(filePath: onPath), serverURL: url))
            }
        }
        return shares
    }

    /// "//user@nas.example.edu/users" + "smbfs" → smb://nas.example.edu/users
    static func serverURL(type: String, mountedFrom from: String) -> URL? {
        let scheme: String
        switch type {
        case "smbfs": scheme = "smb"
        case "afpfs": scheme = "afp"
        case "nfs": scheme = "nfs"
        case "webdav": scheme = "https"
        default: return nil
        }
        if type == "webdav" { return URL(string: from) }
        var rest = from
        if rest.hasPrefix("//") { rest.removeFirst(2) }
        if type == "nfs", let colon = rest.firstIndex(of: ":") {
            // "server:/export/path"
            return URL(string: "nfs://\(rest[..<colon])\(rest[rest.index(after: colon)...])")
        }
        if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        return URL(string: "\(scheme)://\(rest)")
    }

    /// All callers share a bounded, cancellable mount and conservative recovery gate.
    static func mount(_ url: URL) async -> Bool { await ShareMounter.shared.mount(url) }

    static func unmount(_ share: Share) async -> Bool {
        ShareMountSafety.shared.beginUnmount()
        defer { ShareMountSafety.shared.endUnmount() }
        return await withCheckedContinuation { continuation in
            FileManager.default.unmountVolume(at: share.mountPoint, options: [.withoutUI]) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// Whether the server answers on its file-sharing port within a second.
    static func isReachable(_ url: URL) async -> Bool {
        guard let host = url.host() else { return false }
        let port: NWEndpoint.Port = switch url.scheme {
        case "afp": 548
        case "nfs": 2049
        case "https": 443
        default: 445
        }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { connection.cancel(); continuation.resume(returning: true) }
                case .failed, .cancelled, .waiting:
                    if once.take() { connection.cancel(); continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "Tweaks.reach"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if once.take() { connection.cancel(); continuation.resume(returning: false) }
            }
        }
    }
}

/// A thread-safe "first caller wins" flag for resuming a continuation exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Unmounts network shares as the Mac sleeps, so waking on a different network doesn't
/// stall on a server that's gone, and remounts them once the server is reachable again.
@MainActor
final class ShareSleepManager {
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let recovery: ShareRemountQueue
    var onStatus: ((FeatureRuntime) -> Void)? {
        get { recovery.onStatus }
        set { recovery.onStatus = newValue }
    }

    init(defaults: UserDefaults = .standard) {
        recovery = ShareRemountQueue(defaults: defaults)
    }

    func recoverPending() { recovery.resume() }

    func start() {
        guard sleepObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
        // Anything already unmounted still has to come back. A remount that is
        // already running is that restore; don't cancel it.
        recovery.resume()
    }

    private var skipped: [String] = []

    private func willSleep() {
        ShareMountSafety.shared.setSleeping(true)
        recovery.suspend()
        skipped = []
        // Leave shares alone while a render runs or a file on them is open: a render
        // reading footage or writing frames there would fail on the next file.
        let rendering = RenderProcesses.anyRunning()
        var unmounting: [NetworkShares.Share] = []
        for share in NetworkShares.mounted() {
            if rendering || OpenFiles.volumeInUse(share.mountPoint.path) {
                skipped.append(share.mountPoint.lastPathComponent)
            } else {
                unmounting.append(share)
            }
        }
        recovery.enqueue(unmounting.map(\.serverURL))
        for share in unmounting {
            recovery.beginUnmount(share.serverURL)
            ShareMountSafety.shared.beginUnmount()
            FileManager.default.unmountVolume(at: share.mountPoint, options: [.withoutUI]) { [weak self] _ in
                ShareMountSafety.shared.endUnmount()
                Task { @MainActor in self?.recovery.endUnmount(share.serverURL) }
            }
        }
    }

    private func didWake() {
        ShareMountSafety.shared.setSleeping(false)
        if !skipped.isEmpty {
            Notifier.post(title: "Left \(skipped.joined(separator: ", ")) connected during sleep",
                          body: "A file on it was open or a render was running.")
            skipped = []
        }
        recovery.resume()
    }
}

/// Unresolved restores belong to the queue, never to a cancellable retry task.
/// Back off after the initial attempts, but keep trying while the server is away.
@MainActor
final class ShareRemountQueue {
    private(set) var pending: Set<URL>
    var onStatus: ((FeatureRuntime) -> Void)?
    private let defaults: UserDefaults
    private let mounted: @MainActor () -> [URL]
    private let reachable: @MainActor (URL) async -> Bool
    private let mount: @MainActor (URL) async -> Bool
    private let wait: @MainActor (TimeInterval) async throws -> Void
    private let watchConnectivity: Bool
    private var task: Task<Void, Never>?
    private var monitor: ShareConnectivityWatcher?
    private var generation = 0
    private var sleeping = true
    private var unmounting: [URL: Int] = [:]
    /// True while a reachability check or mount is running. Network changes then only
    /// ask for another pass instead of cancelling the mount (which can quarantine it).
    private var busy = false
    private var retryRequested = false
    /// Network events arrive in bursts while a VPN settles; one pass covers a burst.
    static let retryDebounce: TimeInterval = 2
    static let key = "sharesPendingSleepRestore"

    init(defaults: UserDefaults = .standard,
         mounted: @escaping @MainActor () -> [URL] = { NetworkShares.mounted().map(\.serverURL) },
         reachable: @escaping @MainActor (URL) async -> Bool = { await NetworkShares.isReachable($0) },
         mount: @escaping @MainActor (URL) async -> Bool = { await ShareMounter.shared.mount($0) },
         wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         watchConnectivity: Bool = true) {
        self.defaults = defaults
        self.mounted = mounted
        self.reachable = reachable
        self.mount = mount
        self.wait = wait
        self.watchConnectivity = watchConnectivity
        pending = Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(URL.init(string:)))
    }

    func enqueue(_ urls: [URL]) {
        pending.formUnion(urls)
        save()
        if !sleeping { resume() }
    }

    func beginUnmount(_ url: URL) {
        unmounting[url, default: 0] += 1
    }

    func endUnmount(_ url: URL) {
        if let count = unmounting[url], count > 1 { unmounting[url] = count - 1 }
        else { unmounting[url] = nil }
        if !sleeping { retryNow() }
    }

    func suspend() {
        sleeping = true
        busy = false; retryRequested = false
        generation += 1
        task?.cancel()
        task = nil
        monitor?.stop()
        monitor = nil
    }

    func resume() {
        sleeping = false
        onStatus?(.init(phase: pending.isEmpty ? .ready : .waiting, message: pending.isEmpty ? "Watching sleep; no share restores pending." : "Waiting to restore \(pending.count) shares after sleep.", finishingRecovery: !pending.isEmpty))
        guard !pending.isEmpty, task == nil else { return }
        if watchConnectivity, monitor == nil {
            let monitor = ShareConnectivityWatcher { [weak self] in self?.retryNow() }
            monitor.start()
            self.monitor = monitor
        }
        beginRetry(initialDelay: 8)
    }

    func retryNow() {
        guard !sleeping, !pending.isEmpty else { return }
        if busy { retryRequested = true; return }
        generation += 1
        task?.cancel()
        beginRetry(initialDelay: Self.retryDebounce)
    }

    private func beginRetry(initialDelay: TimeInterval) {
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !self.pending.isEmpty {
                let delay: TimeInterval = self.retryRequested ? Self.retryDebounce
                    : (attempt == 0 ? initialDelay : (attempt < 12 ? 15 : 60))
                self.retryRequested = false
                do { try await self.wait(delay) }
                catch { return }
                guard !Task.isCancelled, self.generation == token else { return }
                let missing = Set(ShareAutoConnect.sharesToMount(wanted: Array(self.pending), mounted: self.mounted()))
                // A slow unmount may finish after wake. Its still-mounted path
                // must not be mistaken for a successful restoration.
                self.pending.formIntersection(missing.union(self.unmounting.keys))
                self.save()
                for url in missing {
                    guard self.unmounting[url] == nil else { continue }
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.busy = true
                    let isReachable = await self.reachable(url)
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.busy = false
                    guard isReachable else { continue }
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.busy = true
                    self.onStatus?(.init(phase: .working, message: "Restoring a share after sleep.", finishingRecovery: true))
                    let restored = await self.mount(url)
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.busy = false
                    if restored { self.pending.remove(url); self.save() }
                }
                self.onStatus?(.init(phase: self.pending.isEmpty ? .ready : .waiting, message: self.pending.isEmpty ? "Sleep restores complete." : "Waiting for \(self.pending.count) share restores; retry scheduled.", finishingRecovery: !self.pending.isEmpty))
                attempt += 1
            }
            if self.generation == token {
                self.task = nil
                self.monitor?.stop()
                self.monitor = nil
            }
        }
    }

    private func save() {
        defaults.set(pending.map(\.absoluteString).sorted(), forKey: Self.key)
    }
}

/// Retries missing shares as dock/VPN routes settle, without canceling a mount on
/// every path notification or stacking more requests behind a stalled helper.
@MainActor
final class ShareAutoConnect {
    var shares: [URL] = []
    var onStatus: ((FeatureRuntime) -> Void)?
    static let pollInterval: TimeInterval = 5 * 60
    private let mounted: @MainActor () -> [URL]
    private let reachable: @MainActor (URL) async -> Bool
    private let mount: @MainActor (URL) async -> Bool
    private let wait: @MainActor (TimeInterval) async throws -> Void
    private let watchConnectivity: Bool
    private var monitor: ShareConnectivityWatcher?
    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var running = false
    private var generation = 0
    private var checkAgain = false

    init(mounted: @escaping @MainActor () -> [URL] = { NetworkShares.mounted().map(\.serverURL) },
         reachable: @escaping @MainActor (URL) async -> Bool = { await NetworkShares.isReachable($0) },
         mount: @escaping @MainActor (URL) async -> Bool = { await ShareMounter.shared.mount($0) },
         wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         watchConnectivity: Bool = true) {
        self.mounted = mounted; self.reachable = reachable; self.mount = mount
        self.wait = wait; self.watchConnectivity = watchConnectivity
    }

    func start() {
        guard !running else { return }
        running = true
        if watchConnectivity {
            let watcher = ShareConnectivityWatcher { [weak self] in self?.networkChanged() }
            watcher.start(); monitor = watcher
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.networkChanged() }
            }
            timer.tolerance = 60
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        networkChanged()
    }

    func stop() {
        running = false; generation += 1; checkAgain = false
        ShareMountSafety.shared.invalidate()
        monitor?.stop(); monitor = nil
        timer?.invalidate(); timer = nil
        pending?.cancel(); pending = nil
        checkTask?.cancel(); checkTask = nil
    }

    func networkChanged() {
        guard running else { return }
        guard checkTask == nil else { checkAgain = true; return }
        pending?.cancel()
        if !watchConnectivity { beginCheck(); return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.beginCheck() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func beginCheck() {
        guard running, checkTask == nil else { return }
        pending = nil
        let token = generation
        let wanted = shares
        checkTask = Task { [weak self] in
            guard let self else { return }
            for delay in [0.0, 5, 15, 30, 60] {
                do { try await self.wait(delay) } catch { break }
                guard !Task.isCancelled, self.running, self.generation == token else { break }
                let missing = Self.sharesToMount(wanted: wanted, mounted: self.mounted())
                if missing.isEmpty {
                    self.onStatus?(.init(phase: wanted.isEmpty ? .waiting : .ready, message: wanted.isEmpty ? "Add a work share." : "All \(wanted.count) work shares are connected."))
                    break
                }
                for url in missing {
                    guard !Task.isCancelled, self.running, self.generation == token else { break }
                    let reachable = await self.reachable(url)
                    guard !Task.isCancelled, self.running, self.generation == token else { break }
                    guard reachable else {
                        self.onStatus?(.init(phase: .waiting, message: "Share server unavailable; check the network or VPN. Retry scheduled."))
                        continue
                    }
                    guard !Task.isCancelled, self.running, self.generation == token else { break }
                    self.onStatus?(.init(phase: .working, message: "Connecting a missing work share."))
                    let connected = await self.mount(url)
                    guard !Task.isCancelled, self.running, self.generation == token else { break }
                    self.onStatus?(.init(phase: connected ? .active : .blocked, message: connected ? "A missing work share reconnected." : "Share connection did not complete; retry scheduled. VPN sign-in may be needed."))
                }
            }
            guard self.generation == token else { return }
            self.checkTask = nil
            if self.checkAgain { self.checkAgain = false; self.networkChanged() }
        }
    }

    /// Shares that are wanted but not mounted. A share counts as mounted when the same
    /// share name is mounted from any address, so connecting by IP or an alias doesn't
    /// lead to a second copy at /Volumes/users-1.
    nonisolated static func sharesToMount(wanted: [URL], mounted: [URL]) -> [URL] {
        func shareName(_ url: URL) -> String {
            url.path().split(separator: "/").first.map { String($0).lowercased() } ?? ""
        }
        let mountedNames = Set(mounted.map(shareName))
        return wanted.filter { !mountedNames.contains(shareName($0)) }
    }
}
