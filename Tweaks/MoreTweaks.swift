import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation
import UserNotifications

// MARK: - Eject drives before sleep

/// Ejects external drives as the Mac goes to sleep, so closing the lid with media
/// drives attached doesn't end in "Disk Not Ejected Properly". Anything that refuses
/// (a file still open) is reported after wake.
@MainActor
final class SleepEjector {
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var failed: [String] = []

    func start() {
        guard sleepObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ejectAll() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportFailures() }
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
    }

    /// Local, ejectable, non-internal volumes: USB and Thunderbolt drives and card readers.
    static func externalDrives() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return shouldEject(isLocal: values.volumeIsLocal, isRoot: values.volumeIsRootFileSystem,
                               isInternal: values.volumeIsInternal, isEjectable: values.volumeIsEjectable,
                               isRemovable: values.volumeIsRemovable)
        }
    }

    static func shouldEject(isLocal: Bool?, isRoot: Bool?, isInternal: Bool?, isEjectable: Bool?, isRemovable: Bool?) -> Bool {
        isLocal == true && isRoot != true && isInternal != true && (isEjectable == true || isRemovable == true)
    }

    private func ejectAll() {
        failed = []
        // A render may be writing an image sequence frame by frame, with nothing open
        // between frames; don't pull a drive out from under it.
        if RenderProcesses.anyRunning() { return }
        for drive in Self.externalDrives() {
            if OpenFiles.volumeInUse(drive.path) {
                failed.append(drive.lastPathComponent)
                continue
            }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: drive)
            } catch {
                failed.append(drive.lastPathComponent)
            }
        }
    }

    private func reportFailures() {
        guard !failed.isEmpty else { return }
        Notifier.post(
            title: "Couldn't eject \(failed.joined(separator: ", ")) before sleep",
            body: "A file on it was still open. Close it and eject the drive before unplugging."
        )
        failed = []
    }
}

// MARK: - Stay awake while rendering

/// Keeps the Mac (not the display) awake while After Effects, aerender, Media Encoder or
/// Premiere is busy, so an overnight render isn't cut short by idle sleep. "Busy" means
/// using at least half a core; the hold is released two minutes after the work stops.
@MainActor
@Observable
final class RenderKeepAwake {
    struct Renderer: Sendable {
        let name: String
        let matches: @Sendable (String) -> Bool
    }

    nonisolated static let renderers: [Renderer] = [
        // aerender first: it lives in the After Effects folder but isn't inside the app.
        Renderer(name: "aerender") { $0.hasSuffix("/aerender") },
        Renderer(name: "After Effects") { $0.contains("/Adobe After Effects") && $0.contains(".app/") && !$0.contains("Helper") },
        Renderer(name: "Media Encoder") { $0.contains("/Adobe Media Encoder") && !$0.contains("Helper") },
        Renderer(name: "Premiere Pro") { $0.contains("/Adobe Premiere Pro") && !$0.contains("Helper") },
    ]

    nonisolated static let busyCores = 0.5
    static let releaseAfter: TimeInterval = 120
    /// While nothing is rendering. Launch notifications cover an app starting in between.
    static let idleInterval: TimeInterval = 45
    static let busyInterval: TimeInterval = 15

    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var sampler = CPUSampler()
    private var assertion: IOPMAssertionID = 0
    private var lastBusy: Date?
    private(set) var holdingFor: String?

    func start() {
        guard launchObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        schedule(idle: true)
        check()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let launchObserver { center.removeObserver(launchObserver) }
        if let terminateObserver { center.removeObserver(terminateObserver) }
        launchObserver = nil
        terminateObserver = nil
        timer?.invalidate()
        timer = nil
        timerInterval = nil
        release()
    }

    private func schedule(idle: Bool) {
        let interval = idle ? Self.idleInterval : Self.busyInterval
        guard timerInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = idle ? 15 : 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = interval
    }

    private func check() {
        let snap = sampler.sampleRenderers()
        // aerender waiting on footage from the NAS can sit near 0% CPU; it still counts.
        let busy = Self.busyRenderer(in: snap.usage) ?? (snap.paths.contains(where: RenderProcesses.isRenderer) ? "aerender" : nil)
        let now = Date()
        if let busy {
            lastBusy = now
            hold(for: busy)
        } else if let lastBusy, now.timeIntervalSince(lastBusy) >= Self.releaseAfter {
            release()
            self.lastBusy = nil
        }
        schedule(idle: busy == nil && self.lastBusy == nil)
    }

    /// The first renderer using at least `busyCores`, from per-executable CPU in percent.
    nonisolated static func busyRenderer(in usage: [String: Double]) -> String? {
        for renderer in renderers {
            let cpu = usage.filter { renderer.matches($0.key) }.values.reduce(0, +)
            if cpu >= busyCores * 100 { return renderer.name }
        }
        return nil
    }

    private func hold(for name: String) {
        guard assertion == 0 else {
            holdingFor = name
            return
        }
        let reason = "Rendering in \(name)" as CFString
        if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess {
            holdingFor = name
        } else {
            assertion = 0
        }
    }

    private func release() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        holdingFor = nil
    }
}

/// CPU per executable path since the previous sample, via libproc. Only sees your own
/// processes, which is where render apps run.
struct CPUSampler {
    private var previous: [pid_t: UInt64] = [:]
    private var previousAt: UInt64 = 0

    /// Full path, then CPU, and only for render apps. Everything else is skipped so an
    /// idle Mac isn't paying rusage for every process on a timer.
    mutating func sampleRenderers() -> (paths: [String], usage: [String: Double]) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = mach_absolute_time()
        let elapsed = previousAt == 0 ? 0 : now - previousAt
        var current: [pid_t: UInt64] = [:]
        var paths: [String] = []
        var usage: [String: Double] = [:]
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = String(cString: pathBuffer)
            guard Self.shouldMeasure(path) else { continue }
            paths.append(path)
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            // rusage times share mach_absolute_time's units, so the ratio needs no conversion.
            let ticks = info.ri_user_time + info.ri_system_time
            current[pid] = ticks
            guard elapsed > 0, let before = previous[pid], ticks >= before else { continue }
            usage[path, default: 0] += Double(ticks - before) / Double(elapsed) * 100
        }
        previous = current
        previousAt = now
        return (paths, usage)
    }

    static func shouldMeasure(_ path: String) -> Bool {
        RenderKeepAwake.renderers.contains { $0.matches(path) } || RenderProcesses.isRenderer(path)
    }
}

// MARK: - Clean copied links

/// Strips tracking parameters from links as you copy them. Only touches the clipboard
/// when it holds nothing but a single http(s) link, and never touches concealed items
/// from password managers.
@MainActor
final class LinkCleaner {
    /// Clipboard checks wake the process. Two seconds is soon enough for a paste, and the
    /// tolerance lets the system coalesce the wakeup.
    static let pollInterval: TimeInterval = 2

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "mc_cid", "mc_eid", "igshid", "igsh", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "vero_id", "vero_conv", "mkt_tok", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid", "ref_src", "ref_url",
    ]
    /// Parameters that only mean tracking on particular sites.
    static let siteParameters: [String: Set<String>] = [
        "x.com": ["s", "t"], "twitter.com": ["s", "t"],
        "instagram.com": ["utm_source", "img_index"],
        "linkedin.com": ["trackingId", "refId", "lipi", "midToken", "midSig", "trk"],
        "amazon.com": ["ref_", "pf_rd_r", "pf_rd_p", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "content-id", "psc"],
        "youtube.com": ["si", "feature", "pp"], "youtu.be": ["si", "feature"],
        "spotify.com": ["si"],
    ]
    /// Parameters kept even though they look like tracking, because the page needs them.
    static let keepOnSites: [String: Set<String>] = [
        "youtube.com": ["t", "v", "list", "index"], "youtu.be": ["t"],
    ]

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.75
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let types = Set(pasteboard.types ?? [])
        // Only a single plain link: never rich text, files, several items, password
        // manager secrets or a clipboard manager's own temporary writes.
        let skip: Set<NSPasteboard.PasteboardType> = [
            .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
            .fileURL, .rtf, .html, .init("public.rtf"), .init("public.html"),
        ]
        guard pasteboard.pasteboardItems?.count == 1, types.isDisjoint(with: skip),
              let text = pasteboard.string(forType: .string),
              let cleaned = Self.clean(text), cleaned != text,
              pasteboard.changeCount == lastChangeCount
        else { return }
        let item = NSPasteboardItem()
        item.setString(cleaned, forType: .string)
        item.setString(cleaned, forType: .URL)
        // Lets clipboard managers know this rewrite isn't a new copy.
        item.setString("", forType: .init("org.nspasteboard.AutoGeneratedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
    }

    /// The link without tracking parameters, or nil if the text isn't a single http(s) link.
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), let items = components.queryItems, !items.isEmpty
        else { return nil }
        let site = siteKey(for: host)
        let keep = keepOnSites[site] ?? []
        let extra = siteParameters[site] ?? []
        let filtered = items.filter { item in
            let name = item.name
            if keep.contains(name) { return true }
            if name.lowercased().hasPrefix("utm_") { return false }
            if trackingParameters.contains(name) || extra.contains(name) { return false }
            if site == "amazon.com" && name.hasPrefix("ref") { return false }
            return true
        }
        guard filtered.count != items.count else { return trimmed }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string
    }

    /// "www.youtube.com" → "youtube.com", "smile.amazon.co.uk" → "amazon.com" family.
    static func siteKey(for host: String) -> String {
        let parts = host.split(separator: ".")
        if parts.contains("amazon") { return "amazon.com" }
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }
}

// MARK: - Quit apps when their last window closes

/// Quits the apps you pick once their last window is closed, as Windows apps do.
@MainActor
final class LastWindowQuitter {
    var bundleIDs: Set<String> = []
    static let pollInterval: TimeInterval = 2.5

    private var timer: Timer?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var hadWindows: Set<pid_t> = []
    private var emptyPolls: [pid_t: Int] = [:]

    func start() {
        guard launchObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.armTimerIfNeeded() }
        }
        terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.armTimerIfNeeded() }
        }
        armTimerIfNeeded()
    }

    /// The chosen apps changed while the tweak is already running.
    func appsChanged() {
        guard launchObserver != nil else { return }
        armTimerIfNeeded()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let launchObserver { center.removeObserver(launchObserver) }
        if let terminateObserver { center.removeObserver(terminateObserver) }
        launchObserver = nil
        terminateObserver = nil
        timer?.invalidate()
        timer = nil
        hadWindows = []
        emptyPolls = [:]
    }

    /// No Accessibility queries unless one of the chosen apps is actually running.
    private func armTimerIfNeeded() {
        let running = watchedApplications()
        guard !running.isEmpty else {
            timer?.invalidate()
            timer = nil
            hadWindows = []
            emptyPolls = [:]
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.8
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func watchedApplications() -> [NSRunningApplication] {
        guard !bundleIDs.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier.map(bundleIDs.contains) == true && !app.isTerminated
        }
    }

    private func check() {
        guard AX.isTrusted, !bundleIDs.isEmpty else { return }
        let running = watchedApplications()
        if running.isEmpty {
            armTimerIfNeeded()
            return
        }
        let livePIDs = Set(running.map(\.processIdentifier))
        hadWindows.formIntersection(livePIDs)
        emptyPolls = emptyPolls.filter { livePIDs.contains($0.key) }
        for app in running {
            let pid = app.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            // A busy app shouldn't stall Tweaks (or the clicks its event tap sees).
            AXUIElementSetMessagingTimeout(element, 0.25)
            var value: AnyObject?
            // Only a successful answer counts: a timed-out query is not "no windows".
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement]
            else {
                emptyPolls[pid] = 0
                continue
            }
            let standard = windows.filter { (AX.attribute($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
            if standard.isEmpty {
                emptyPolls[pid, default: 0] += 1
            } else {
                emptyPolls[pid] = 0
                hadWindows.insert(pid)
            }
            if Self.shouldQuit(hadWindows: hadWindows.contains(pid), windowCount: standard.count, emptyPolls: emptyPolls[pid] ?? 0) {
                app.terminate()
                hadWindows.remove(pid)
                emptyPolls[pid] = nil
            }
        }
    }

    /// Only after the app had a window and now has none, so launching an app to the
    /// background (or one still opening its first window) isn't quit.
    /// Two empty answers in a row (3 s) so a window being replaced isn't mistaken for the last one closing.
    static func shouldQuit(hadWindows: Bool, windowCount: Int, emptyPolls: Int = 2) -> Bool {
        hadWindows && windowCount == 0 && emptyPolls >= 2
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
