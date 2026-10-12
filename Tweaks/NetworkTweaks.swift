import AppKit
import Foundation
import IOKit.ps
import NetFS
import Network
import SystemConfiguration

// MARK: - Wi-Fi off while on Ethernet

/// Turns Wi-Fi off while a wired connection is live (docked), so traffic can't quietly
/// go over the wrong one, and back on when the wire goes away. Wi-Fi is only turned back
/// on if Tweaks was the one that turned it off.
@MainActor
final class WiFiWhenWired {
    private var monitor: NWPathMonitor?
    private var pending: DispatchWorkItem?
    private var turnedOffByTweaks: Bool {
        get { UserDefaults.standard.bool(forKey: "wifiTurnedOffByTweaks") }
        set { UserDefaults.standard.set(newValue, forKey: "wifiTurnedOffByTweaks") }
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        monitor.pathUpdateHandler = { [weak self] path in
            let wired = path.status == .satisfied
            Task { @MainActor in self?.wiredChanged(wired) }
        }
        monitor.start(queue: DispatchQueue(label: "Tweaks.wired"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        pending?.cancel()
        // Don't strand the Mac without Wi-Fi when the tweak is switched off.
        if turnedOffByTweaks {
            WiFiPower.set(on: true)
            turnedOffByTweaks = false
        }
    }

    /// Waits a few seconds so plugging in or a brief link flap doesn't toggle Wi-Fi.
    private func wiredChanged(_ wired: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.apply(wired: wired) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func apply(wired: Bool) {
        switch Self.decision(wired: wired, wifiOn: WiFiPower.isOn(), turnedOffByTweaks: turnedOffByTweaks) {
        case .turnOff:
            if WiFiPower.set(on: false) { turnedOffByTweaks = true }
        case .turnOn:
            WiFiPower.set(on: true)
            turnedOffByTweaks = false
        case .nothing:
            break
        }
    }

    enum Decision: Equatable { case turnOff, turnOn, nothing }

    static func decision(wired: Bool, wifiOn: Bool?, turnedOffByTweaks: Bool) -> Decision {
        if wired { return wifiOn == true ? .turnOff : .nothing }
        return turnedOffByTweaks ? .turnOn : .nothing
    }
}

/// Wi-Fi power through `networksetup`, which works for an admin user without sudo.
enum WiFiPower {
    static func device() -> String? {
        guard let output = run(["-listallhardwareports"]) else { return nil }
        return parseDevice(output)
    }

    static func parseDevice(_ output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.hasPrefix("Hardware Port: Wi-Fi") || line.hasPrefix("Hardware Port: AirPort") {
            if index + 1 < lines.count, lines[index + 1].hasPrefix("Device: ") {
                return String(lines[index + 1].dropFirst("Device: ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func isOn() -> Bool? {
        guard let device = device(), let output = run(["-getairportpower", device]) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("On")
    }

    @discardableResult
    static func set(on: Bool) -> Bool {
        guard let device = device() else { return false }
        return run(["-setairportpower", device, on ? "on" : "off"]) != nil
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

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

    private func willSleep() {
        let shares = NetworkShares.mounted()
        toRemount = shares.map(\.serverURL)
        // The Mac gives sleep handlers a short window; force-unmount so a busy share
        // can't hold sleep up.
        for share in shares {
            FileManager.default.unmountVolume(at: share.mountPoint, options: [.withoutUI]) { _ in }
        }
    }

    private func didWake() {
        let urls = toRemount
        toRemount = []
        guard !urls.isEmpty else { return }
        Task {
            // Give Wi-Fi or VPN time to come back before trying.
            for attempt in 0..<12 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 8 : 15))
                var remaining: [URL] = []
                for url in urls where !NetworkShares.mounted().contains(where: { $0.serverURL == url }) {
                    if await NetworkShares.isReachable(url), await NetworkShares.mount(url) { continue }
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
                _ = await NetworkShares.mount(url)
            }
        }
    }

    /// Shares that are wanted but not mounted; compares host and path, ignoring case and
    /// a trailing slash.
    static func sharesToMount(wanted: [URL], mounted: [URL]) -> [URL] {
        func key(_ url: URL) -> String {
            var text = "\(url.scheme ?? "")://\(url.host() ?? "")\(url.path())".lowercased()
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        let mountedKeys = Set(mounted.map(key))
        return wanted.filter { !mountedKeys.contains(key($0)) }
    }
}

// MARK: - Bluetooth off while asleep

/// Turns Bluetooth off when the Mac sleeps on battery (in a bag) and back on at wake.
/// Skipped on power so a Bluetooth keyboard can still wake a docked Mac.
@MainActor
final class BluetoothSleep {
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var turnedOff = false

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
        if turnedOff { BluetoothPower.set(on: true) }
        turnedOff = false
    }

    private func willSleep() {
        guard PowerSource.isOnBattery, BluetoothPower.isOn == true else { return }
        BluetoothPower.set(on: false)
        turnedOff = true
    }

    private func didWake() {
        guard turnedOff else { return }
        BluetoothPower.set(on: true)
        turnedOff = false
    }
}

/// Bluetooth controller power. macOS has no public API for this, so it uses the same
/// IOBluetooth preference functions as the `blueutil` tool, looked up at runtime; if a
/// future macOS removes them the tweak simply does nothing.
enum BluetoothPower {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    // A dlopen handle is immutable once loaded and safe to share.
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

    static var isAvailable: Bool {
        dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") != nil
            && dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") != nil
    }

    static var isOn: Bool? {
        guard let symbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: Getter.self)() != 0
    }

    static func set(on: Bool) {
        guard let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(symbol, to: Setter.self)(on ? 1 : 0)
    }
}

enum PowerSource {
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
