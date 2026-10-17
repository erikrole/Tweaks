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

    static func mounted() -> [Share] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
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

    /// Mounts silently with credentials from the keychain (as Finder saved them).
    static func mount(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var mountPoints: Unmanaged<CFArray>?
                let openOptions = NSMutableDictionary()
                openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
                let status = NetFSMountURLSync(url as CFURL, nil, nil, nil, openOptions, nil, &mountPoints)
                mountPoints?.release()
                continuation.resume(returning: status == 0 || status == EEXIST)
            }
        }
    }

    static func unmount(_ share: Share) async -> Bool {
        await withCheckedContinuation { continuation in
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

/// Serialises mount attempts so a half-up VPN can't stack several slow mounts of the
/// same share.
actor ShareMounter {
    static let shared = ShareMounter()
    private var inFlight: Set<URL> = []

    func mount(_ url: URL) async -> Bool {
        guard !inFlight.contains(url) else { return false }
        inFlight.insert(url)
        defer { inFlight.remove(url) }
        return await NetworkShares.mount(url)
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
            FileManager.default.unmountVolume(at: share.mountPoint, options: [.withoutUI]) { [weak self] _ in
                Task { @MainActor in self?.recovery.endUnmount(share.serverURL) }
            }
        }
    }

    private func didWake() {
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
    private let defaults: UserDefaults
    private let mounted: @MainActor () -> [URL]
    private let reachable: @MainActor (URL) async -> Bool
    private let mount: @MainActor (URL) async -> Bool
    private let wait: @MainActor (TimeInterval) async throws -> Void
    private let watchConnectivity: Bool
    private var task: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var generation = 0
    private var sleeping = true
    private var unmounting: [URL: Int] = [:]
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
        generation += 1
        task?.cancel()
        task = nil
        monitor?.cancel()
        monitor = nil
    }

    func resume() {
        sleeping = false
        guard !pending.isEmpty, task == nil else { return }
        if watchConnectivity, monitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in self?.retryNow() }
            }
            monitor.start(queue: DispatchQueue(label: "Tweaks.share-restore"))
            self.monitor = monitor
        }
        beginRetry(initialDelay: 8)
    }

    func retryNow() {
        guard !sleeping, !pending.isEmpty else { return }
        generation += 1
        task?.cancel()
        beginRetry(initialDelay: 0)
    }

    private func beginRetry(initialDelay: TimeInterval) {
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !self.pending.isEmpty {
                do { try await self.wait(attempt == 0 ? initialDelay : (attempt < 12 ? 15 : 60)) }
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
                    guard await self.reachable(url) else { continue }
                    guard !Task.isCancelled, self.generation == token else { return }
                    let restored = await self.mount(url)
                    guard !Task.isCancelled, self.generation == token else { return }
                    if restored { self.pending.remove(url); self.save() }
                }
                attempt += 1
            }
            if self.generation == token {
                self.task = nil
                self.monitor?.cancel()
                self.monitor = nil
            }
        }
    }

    private func save() {
        defaults.set(pending.map(\.absoluteString).sorted(), forKey: Self.key)
    }
}

/// Keeps your work shares connected: whenever the network changes and a share's server
/// is reachable (office network or VPN), it's mounted if it isn't already.
@MainActor
final class ShareAutoConnect {
    var shares: [URL] = []
    /// Backup for VPNs that connect without a path change.
    static let pollInterval: TimeInterval = 5 * 60

    private var monitor: NWPathMonitor?
    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.scheduleCheck() }
        }
        monitor.start(queue: DispatchQueue(label: "Tweaks.shares"))
        self.monitor = monitor
        // VPNs often connect without a path change; check every few minutes as well.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduleCheck()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        checkTask?.cancel()
        checkTask = nil
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func check() {
        let wanted = shares
        checkTask?.cancel()
        checkTask = Task {
            let mounted = NetworkShares.mounted().map(\.serverURL)
            for url in Self.sharesToMount(wanted: wanted, mounted: mounted) {
                if Task.isCancelled { return }
                guard await NetworkShares.isReachable(url) else { continue }
                if Task.isCancelled { return }
                _ = await ShareMounter.shared.mount(url)
            }
        }
    }

    /// Shares that are wanted but not mounted. A share counts as mounted when the same
    /// share name is mounted from any address, so connecting by IP or an alias doesn't
    /// lead to a second copy at /Volumes/users-1.
    static func sharesToMount(wanted: [URL], mounted: [URL]) -> [URL] {
        func shareName(_ url: URL) -> String {
            url.path().split(separator: "/").first.map { String($0).lowercased() } ?? ""
        }
        let mountedNames = Set(mounted.map(shareName))
        return wanted.filter { !mountedNames.contains(shareName($0)) }
    }
}
