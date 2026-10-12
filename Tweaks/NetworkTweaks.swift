import AppKit
import Foundation
import NetFS
import Network
import SystemConfiguration

// MARK: - Network shares

/// Mounted network shares (SMB, AFP, NFS, WebDAV) and their server URLs.
enum NetworkShares {
    struct Share: Equatable, Sendable {
        let mountPoint: URL
        /// "smb://ath01-nas.uwia.wisc.edu/users", without the user name.
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

    /// "//role@ath01-nas.uwia.wisc.edu/users" + "smbfs" → smb://ath01-nas.uwia.wisc.edu/users
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
    private var toRemount: [URL] = []

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
    }

    private var skipped: [String] = []

    private func willSleep() {
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
        toRemount = unmounting.map(\.serverURL)
        for share in unmounting {
            FileManager.default.unmountVolume(at: share.mountPoint, options: [.withoutUI]) { _ in }
        }
    }

    private func didWake() {
        if !skipped.isEmpty {
            Notifier.post(title: "Left \(skipped.joined(separator: ", ")) connected during sleep",
                          body: "A file on it was open or a render was running.")
            skipped = []
        }
        let urls = toRemount
        toRemount = []
        guard !urls.isEmpty else { return }
        Task {
            // Give Wi-Fi or VPN time to come back before trying.
            for attempt in 0..<12 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 8 : 15))
                var remaining: [URL] = []
                for url in ShareAutoConnect.sharesToMount(wanted: urls, mounted: NetworkShares.mounted().map(\.serverURL)) {
                    if await NetworkShares.isReachable(url), await ShareMounter.shared.mount(url) { continue }
                    remaining.append(url)
                }
                if remaining.isEmpty { return }
            }
        }
    }
}

/// Keeps your work shares connected: whenever the network changes and a share's server
/// is reachable (office network or VPN), it's mounted if it isn't already.
@MainActor
final class ShareAutoConnect {
    var shares: [URL] = []
    private var monitor: NWPathMonitor?
    private var pending: DispatchWorkItem?
    private var timer: Timer?

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
        let timer = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        timer.tolerance = 30
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
        Task {
            let mounted = NetworkShares.mounted().map(\.serverURL)
            for url in Self.sharesToMount(wanted: wanted, mounted: mounted) where await NetworkShares.isReachable(url) {
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
