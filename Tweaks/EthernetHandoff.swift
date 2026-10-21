import Foundation
import SystemConfiguration
import Darwin
import AppKit
import os


struct EthernetVPNRoute: Equatable, Sendable {
    var interface: String?
    var isStaticHost: Bool
    var destination: String?
    init(_ text: String) {
        interface = nil
        isStaticHost = false
        destination = nil
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "interface" { interface = parts[1] }
            if parts[0] == "destination" { destination = parts[1] }
            if parts[0] == "flags" {
                let flags = Set(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "<>")).split(separator: ",").map(String.init))
                isStaticHost = flags.contains("HOST") && flags.contains("STATIC")
            }
        }
    }
}

enum EthernetHandoffPolicy {
    static func isWired(type: String, name: String, displayName: String = "") -> Bool {
        type == "Ethernet" && !name.hasPrefix("bridge") && !name.hasPrefix("utun")
            && !isTethering(displayName)
    }

    /// iPhone, iPad and Android USB tethering report as Ethernet with a router; moving the
    /// VPN there would put it on cellular.
    static func isTethering(_ displayName: String) -> Bool {
        let lowered = displayName.lowercased()
        return ["iphone", "ipad", "android", "rndis", "tether"].contains { lowered.contains($0) }
    }

    static func portalHost(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value.contains("://") ? value : "https://" + value),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host, !host.isEmpty, host.count <= 253,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              host.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }) else { return nil }
        return host.lowercased()
    }

    static func shouldHandoff(ethernetReady: Bool, wifiOn: Bool, attempted: Bool,
                                     secondsSinceAttempt: TimeInterval, defaultRoute: EthernetVPNRoute,
                                     gatewayRoute: EthernetVPNRoute, wifiInterface: String,
                                     globalProtectConnected: Bool = false) -> Bool {
        ethernetReady && wifiOn && !attempted && secondsSinceAttempt >= 300
        && globalProtectConnected
        && defaultRoute.interface?.hasPrefix("utun") == true
        && gatewayRoute.isStaticHost && gatewayRoute.interface == wifiInterface
    }
}

struct EthernetHandoffSavedState: Codable {
    var wifiRestoreNeeded = false
    var lastAttempt: TimeInterval = 0
    /// Wired connection, VPN gateway and VPN address of the last attempt. One attempt per
    /// combination: a dock that flaps or a wake doesn't cycle Wi-Fi again for the same VPN session.
    var lastAttemptKey: String?

    init(wifiRestoreNeeded: Bool = false, lastAttempt: TimeInterval = 0, lastAttemptKey: String? = nil) {
        self.wifiRestoreNeeded = wifiRestoreNeeded
        self.lastAttempt = lastAttempt
        self.lastAttemptKey = lastAttemptKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        wifiRestoreNeeded = try values.decodeIfPresent(Bool.self, forKey: .wifiRestoreNeeded) ?? false
        lastAttempt = try values.decodeIfPresent(TimeInterval.self, forKey: .lastAttempt) ?? 0
        lastAttemptKey = try values.decodeIfPresent(String.self, forKey: .lastAttemptKey)
    }

    /// Reads saved state. A file that exists but can't be read or decoded may hide a
    /// pending restore, so it is treated as one: Wi-Fi is turned back on rather than left off.
    static func load(from url: URL) -> (state: EthernetHandoffSavedState, damaged: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.init(), false) }
        guard let bytes = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(EthernetHandoffSavedState.self, from: bytes) else {
            return (.init(wifiRestoreNeeded: true), true)
        }
        return (state, false)
    }
}

struct EthernetHandoffConnection {
    var interface: String
    var address: String
    var router: String
}

struct EthernetHandoffCommandResult {
    var status: Int32
    var text: String
}

private func ethernetHandoffCommand(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> EthernetHandoffCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return EthernetHandoffCommandResult(status: -1, text: error.localizedDescription) }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1)
        }
        return EthernetHandoffCommandResult(status: -2, text: "Command timed out")
    }
    return EthernetHandoffCommandResult(status: process.terminationStatus,
                         text: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

final class EthernetHandoffWorker: @unchecked Sendable {
    let directory: URL
    private let commandRunner: @Sendable (String, [String], TimeInterval) -> EthernetHandoffCommandResult
    private let wifiProvider: (@Sendable () -> String?)?
    private let recoveryInterval: TimeInterval
    let queue = DispatchQueue(label: "Tweaks.Ethernet.network", qos: .utility)
    private let stopLock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private var prepared = false
    private var lockFD: Int32 = -1
    private var restoreRetryTimer: DispatchSourceTimer?
    private var inspectTimer: DispatchSourceTimer?
    private var restoreRetryDelay: TimeInterval
    private var store: SCDynamicStore?
    private var scheduled: DispatchWorkItem?
    private var attempted = false
    private var readySince: Date?
    private var wiredIdentity: String?
    private var saved: EthernetHandoffSavedState

    init(directory: URL,
         commandRunner: @escaping @Sendable (String, [String], TimeInterval) -> EthernetHandoffCommandResult = { path, args, timeout in
             ethernetHandoffCommand(path, args, timeout: timeout)
         },
         wifiProvider: (@Sendable () -> String?)? = nil,
         recoveryInterval: TimeInterval = 5) {
        self.directory = directory; self.saved = .init()
        self.commandRunner = commandRunner; self.wifiProvider = wifiProvider
        self.recoveryInterval = recoveryInterval
        self.restoreRetryDelay = recoveryInterval
    }

    deinit { restoreRetryTimer?.cancel(); inspectTimer?.cancel(); if lockFD >= 0 { close(lockFD) } }

    /// The longest wait between Wi-Fi restore retries once earlier ones fail.
    static let maxRestoreRetryDelay: TimeInterval = 300

    private func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> EthernetHandoffCommandResult {
        commandRunner(path, args, timeout)
    }

    private func prepare() -> Bool {
        if prepared { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { return false }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
            lockFD = fd
            let loaded = EthernetHandoffSavedState.load(from: directory.appendingPathComponent("state.json"))
            saved = loaded.state
            prepared = true
            if loaded.damaged { log("Saved state unreadable; restoring Wi-Fi to be safe") }
            return true
        } catch { return false }
    }

    func recoverPending() {
        queue.async { [self] in
            guard prepare() else { return }
            if !restoreWifiIfNeeded() { armRecoveryOnly() }
        }
    }

    func start() {
        stopLock.lock()
        if enabled { stopLock.unlock(); return }
        enabled = true; generation &+= 1
        let session = generation
        stopLock.unlock()
        queue.async { [self] in
            guard isCurrent(session), prepare() else { return }
            do { try beginMonitoring() } catch {
                log("Could not start Ethernet monitoring")
                if saved.wifiRestoreNeeded { armRecoveryOnly() }
            }
        }
    }

    func stop(completion: (@Sendable (Bool) -> Void)? = nil) {
        stopLock.lock(); enabled = false; generation &+= 1; stopLock.unlock()
        queue.async { [self] in
            scheduled?.cancel(); scheduled = nil
            restoreRetryTimer?.cancel(); restoreRetryTimer = nil
            inspectTimer?.cancel(); inspectTimer = nil
            if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
            store = nil
            let restored = prepare() ? restoreWifiIfNeeded() : !saved.wifiRestoreNeeded
            if !restored { armRecoveryOnly() }
            wiredIdentity = nil; readySince = nil; attempted = false
            completion?(restored)
        }
    }

    /// Retries a pending Wi-Fi restore, backing off from `recoveryInterval` to five minutes.
    private func armRecoveryOnly() {
        restoreRetryTimer?.cancel()
        let retry = DispatchSource.makeTimerSource(queue: queue)
        retry.schedule(deadline: .now() + min(3, restoreRetryDelay))
        retry.setEventHandler { [weak self] in
            guard let self else { return }
            restoreRetryTimer = nil
            guard prepare(), restoreWifiIfNeeded() else {
                restoreRetryDelay = min(restoreRetryDelay * 2, Self.maxRestoreRetryDelay)
                armRecoveryOnly()
                return
            }
            restoreRetryDelay = recoveryInterval
            if currentSession() != nil && store == nil { try? beginMonitoring() }
        }
        retry.resume()
        restoreRetryTimer = retry
    }

    private func currentSession() -> UInt64? {
        stopLock.lock(); defer { stopLock.unlock() }; return enabled ? generation : nil
    }

    private func isCurrent(_ session: UInt64) -> Bool { currentSession() == session }

    func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        Logger(subsystem: "com.erole.Tweaks", category: "EthernetHandoff").info("\(message, privacy: .public)")
        let url = directory.appendingPathComponent("events.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 131_072 {
            let old = directory.appendingPathComponent("events.previous.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }

    private func persist() throws {
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    func wifiInterface() -> String? {
        if let wifiProvider { return wifiProvider() }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let names = interfaces.filter { SCNetworkInterfaceGetInterfaceType($0) as String? == kSCNetworkInterfaceTypeIEEE80211 as String }
            .compactMap { SCNetworkInterfaceGetBSDName($0) as String? }
        return names.count == 1 ? names[0] : nil
    }

    func wiredConnection() -> EthernetHandoffConnection? {
        guard let prefs = SCPreferencesCreate(nil, "Tweaks.Ethernet" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return nil }
        let order = SCNetworkSetCopyCurrent(prefs).flatMap { SCNetworkSetGetServiceOrder($0) as? [String] } ?? []
        let ordered = services.sorted {
            (order.firstIndex(of: SCNetworkServiceGetServiceID($0) as String? ?? "") ?? Int.max)
            < (order.firstIndex(of: SCNetworkServiceGetServiceID($1) as String? ?? "") ?? Int.max)
        }
        guard let state = SCDynamicStoreCreate(nil, "Tweaks.Ethernet.read" as CFString, nil, nil) else { return nil }
        for service in ordered where SCNetworkServiceGetEnabled(service) {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  EthernetHandoffPolicy.isWired(type: type, name: name,
                                                displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? ""),
                  let id = SCNetworkServiceGetServiceID(service) as String?,
                  let link = SCDynamicStoreCopyValue(state, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any],
                  link["Active"] as? Bool == true,
                  let ip = SCDynamicStoreCopyValue(state, "State:/Network/Service/\(id)/IPv4" as CFString) as? [String: Any],
                  let address = (ip["Addresses"] as? [String])?.first,
                  !address.hasPrefix("169.254."),
                  let router = ip["Router"] as? String, router != "0.0.0.0" else { continue }
            return EthernetHandoffConnection(interface: name, address: address, router: router)
        }
        return nil
    }

    private func configuredGatewayHost() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.paloaltonetworks.GlobalProtect.settings.plist")
        guard let bytes = try? Data(contentsOf: path),
              let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let vendor = plist["Palo Alto Networks"] as? [String: Any],
              let gp = vendor["GlobalProtect"] as? [String: Any],
              let settings = gp["Settings"] as? [String: Any],
              let raw = settings["LastUrl"] as? String else { return nil }
        return EthernetHandoffPolicy.portalHost(raw)
    }

    private func wifiOn(_ interface: String) -> Bool {
        let result = runCommand("/usr/sbin/networksetup", ["-getairportpower", interface])
        return result.status == 0 && result.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(": On")
    }

    private func route(_ target: String) -> EthernetVPNRoute {
        EthernetVPNRoute(runCommand("/sbin/route", ["-n", "get", target]).text)
    }

    private func globalProtectOwnsDefaultRoute(_ route: EthernetVPNRoute) -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "Tweaks.Ethernet.owner" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              global["PrimaryService"] as? String == "gpd.pan",
              let gp = SCDynamicStoreCopyValue(store, "State:/Network/Service/gpd.pan/IPv4" as CFString) as? [String: Any],
              let interface = gp["InterfaceName"] as? String else { return false }
        return route.interface == interface && (gp["Addresses"] as? [String])?.isEmpty == false
    }

    private func vpnAddress() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Tweaks.Ethernet.vpn" as CFString, nil, nil),
              let gp = SCDynamicStoreCopyValue(store, "State:/Network/Service/gpd.pan/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return (gp["Addresses"] as? [String])?.first
    }

    /// Sleeps in short steps; false as soon as the session ends (stop or quit).
    private func pause(_ seconds: TimeInterval, _ session: UInt64) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            guard isCurrent(session) else { return false }
            Thread.sleep(forTimeInterval: min(0.25, end.timeIntervalSinceNow))
        }
        return isCurrent(session)
    }

    private func gatewayReachable(_ address: String?, on interface: String) -> Bool {
        guard let address else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var index = if_nametoindex(interface)
        guard index != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else { return false }
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = UInt16(443).bigEndian
        guard inet_pton(AF_INET, address, &endpoint.sin_addr) == 1,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { return false }
        let status = withUnsafePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if status == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, 3000) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }

    @discardableResult
    func restoreWifiIfNeeded() -> Bool {
        guard saved.wifiRestoreNeeded else { return true }
        guard let wifi = wifiInterface() else { log("Restore pending: Wi-Fi interface unavailable"); return false }
        let result = runCommand("/usr/sbin/networksetup", ["-setairportpower", wifi, "on"])
        guard result.status == 0 && wifiOn(wifi) else { log("Restore pending: could not restore Wi-Fi"); return false }
        saved.wifiRestoreNeeded = false
        do { try persist() } catch { log("Could not save restored state") }
        log("Wi-Fi restored")
        return true
    }

    func inspect() {
        guard let session = currentSession(), restoreWifiIfNeeded() else { return }
        guard let wired = wiredConnection() else {
            if wiredIdentity != nil { log("Dock Ethernet unavailable; waiting") }
            wiredIdentity = nil; readySince = nil; attempted = false
            return
        }
        let identity = "\(wired.interface):\(wired.address):\(wired.router)"
        if wiredIdentity != identity {
            wiredIdentity = identity; readySince = Date(); attempted = false
            log("Dock Ethernet detected; allowing DHCP and routes to settle")
            schedule(after: 4)
            return
        }
        guard let readySince, Date().timeIntervalSince(readySince) >= 3,
              let wifi = wifiInterface() else { return }
        let defaultRoute = route("default")
        guard let gatewayHost = configuredGatewayHost() else { return }
        let gatewayRoute = route(gatewayHost)
        guard EthernetHandoffPolicy.shouldHandoff(ethernetReady: true, wifiOn: wifiOn(wifi), attempted: attempted,
                                         secondsSinceAttempt: Date().timeIntervalSince1970 - saved.lastAttempt,
                                         defaultRoute: defaultRoute, gatewayRoute: gatewayRoute,
                                         wifiInterface: wifi,
                                         globalProtectConnected: globalProtectOwnsDefaultRoute(defaultRoute)) else { return }
        // A live router on the wired address is required before touching Wi-Fi.
        let ping = runCommand("/sbin/ping", ["-b", wired.interface, "-S", wired.address, "-c", "1", "-W", "1000", wired.router], timeout: 3)
        guard ping.status == 0, isCurrent(session) else { log("Handoff skipped: wired router not reachable"); return }
        guard gatewayReachable(gatewayRoute.destination, on: wired.interface), isCurrent(session) else {
            log("Handoff skipped: VPN gateway not reachable through Ethernet")
            return
        }
        guard let gatewayAddress = gatewayRoute.destination else { return }
        let attemptKey = "\(identity)|\(gatewayAddress)|\(vpnAddress() ?? "")"
        guard saved.lastAttemptKey != attemptKey else { attempted = true; return }
        attempted = true
        saved.lastAttemptKey = attemptKey
        saved.lastAttempt = Date().timeIntervalSince1970
        saved.wifiRestoreNeeded = true
        do { try persist() } catch { log("Handoff skipped: recovery state could not be saved"); saved.wifiRestoreNeeded = false; return }
        log("VPN is still using Wi-Fi; starting one bounded Ethernet handoff")
        defer { _ = restoreWifiIfNeeded() }
        let result = runCommand("/usr/sbin/networksetup", ["-setairportpower", wifi, "off"])
        guard result.status == 0 else { log("Handoff failed: macOS refused Wi-Fi power change"); return }
        let deadline = Date().addingTimeInterval(12)
        var recovered = false
        while Date() < deadline && isCurrent(session) {
            guard let current = wiredConnection(), current.interface == wired.interface else {
                log("Dock removed during handoff; restoring Wi-Fi"); return
            }
            if route(gatewayAddress).interface == wired.interface && route("default").interface?.hasPrefix("utun") == true {
                recovered = true
                break
            }
            _ = pause(0.5, session)
        }
        guard restoreWifiIfNeeded() else { log("Handoff incomplete: Wi-Fi restoration is pending"); return }
        guard recovered, isCurrent(session) else {
            log("Handoff wait ended; no retry and no authentication changes")
            return
        }
        // Wi-Fi is back; anything after this is only verification, so a stop or quit skips it.
        guard pause(3, session) else { return }
        guard route(gatewayAddress).interface == wired.interface,
              globalProtectOwnsDefaultRoute(route("default")) else {
            log("Handoff incomplete: VPN did not remain on Ethernet after Wi-Fi restoration")
            return
        }
        guard isCurrent(session) else { return }
        let check = runCommand("/usr/bin/curl", ["--fail", "--silent", "--output", "/dev/null", "--connect-timeout", "3", "--max-time", "5", "https://www.apple.com/library/test/success.html"], timeout: 6)
        guard check.status == 0 else { log("Ethernet route verified; HTTPS connectivity check did not complete"); return }
        log("Verified: VPN uses Ethernet, Wi-Fi is restored, HTTPS is reachable")
    }

    private func schedule(after delay: TimeInterval = 2) {
        scheduled?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.inspect() }
        scheduled = job
        queue.asyncAfter(deadline: .now() + delay, execute: job)
    }

    private func beginMonitoring() throws {
        guard restoreWifiIfNeeded() else { throw NSError(domain: "Tweaks.Ethernet.restore", code: 1) }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "Tweaks.Ethernet" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<EthernetHandoffWorker>.fromOpaque(info).takeUnretainedValue().schedule()
        }, &context)
        guard let store else { throw NSError(domain: "Tweaks.Ethernet", code: 1) }
        let patterns = ["State:/Network/Interface/.*/Link", "State:/Network/Service/.*/IPv4", "State:/Network/Global/IPv4"]
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue) else { throw NSError(domain: "Tweaks.Ethernet", code: 2) }
        log("Started; watching dock Ethernet and VPN routes")
        queue.async { [self] in inspect() }
        // Recovery is retried even if a crashed process left no subsequent network event.
        let recovery = DispatchSource.makeTimerSource(queue: queue)
        recovery.schedule(deadline: .now() + 30, repeating: 30)
        recovery.setEventHandler { [weak self] in self?.inspect() }
        recovery.resume()
        inspectTimer?.cancel()
        restoreRetryTimer?.cancel(); restoreRetryTimer = nil
        inspectTimer = recovery
    }
}


/// Owns the optional feature; all network and file operations stay on its worker queue.
@MainActor
final class EthernetVPNHandoff {
    private let worker: EthernetHandoffWorker

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.erole.Tweaks/EthernetHandoff")
        worker = EthernetHandoffWorker(directory: base)
    }

    func recoverPending() { worker.recoverPending() }
    func start() { worker.start() }
    func stop() { worker.stop() }

    func prepareForTermination(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        worker.stop { restored in Task { @MainActor in completion(restored) } }
    }
}
