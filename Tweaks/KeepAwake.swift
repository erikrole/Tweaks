import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// A smarter caffeinate. Tap Hyper+/ (⌃⌥⇧⌘/) for 12 hours (tap again to stop, or to add
/// an hour once it's about to end); hold it for the Keep Awake panel. Sessions can run
/// for a while, until a time, until an app quits, until a job finishes (render, downloads,
/// upload, NAS copy), or until you stop them. A cup in the menu bar shows time left. It
/// also answers tweaks://awake links for scripts.
@MainActor
@Observable
final class KeepAwake {
    enum Until: Equatable {
        case indefinitely
        case date(Date)
        case appQuits(pid: pid_t, name: String)
        case done(JobCondition)
    }

    struct Session: Equatable {
        var until: Until
        var keepsDisplayOn: Bool
        var onlyOnPower: Bool
        let startedAt: Date
        var warned = false
        var pausedOnBattery = false
    }

    private(set) var session: Session?
    var keepsDisplayOnByDefault: Bool {
        didSet { UserDefaults.standard.set(keepsDisplayOnByDefault, forKey: "keepAwakeDisplayOn") }
    }
    var onlyOnPowerByDefault: Bool {
        didSet { UserDefaults.standard.set(onlyOnPowerByDefault, forKey: "keepAwakeOnlyOnPower") }
    }
    var showsCountdown: Bool {
        didSet {
            UserDefaults.standard.set(showsCountdown, forKey: "keepAwakeCountdown")
            updateStatusItem()
        }
    }
    /// Recent choices, newest first, shown at the top of the panel.
    private(set) var recents: [Choice] = []

    /// Ends a session on battery at or below this, so a forgotten one can't drain the Mac.
    static let batteryFloor = 15
    /// The heads-up comes this long before a timed session ends.
    static let warningLead: TimeInterval = 5 * 60
    static let defaultDuration: TimeInterval = 12 * 3600

    /// How often a running session is checked. The five-minute warning doesn't need a tighter loop.
    static let watchInterval: TimeInterval = 30

    private var assertion: IOPMAssertionID = 0
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var watcher = JobWatcher()

    init() {
        let defaults = UserDefaults.standard
        keepsDisplayOnByDefault = defaults.bool(forKey: "keepAwakeDisplayOn")
        onlyOnPowerByDefault = defaults.bool(forKey: "keepAwakeOnlyOnPower")
        showsCountdown = defaults.object(forKey: "keepAwakeCountdown") as? Bool ?? true
        if let data = defaults.data(forKey: "keepAwakeRecents"),
           let saved = try? JSONDecoder().decode([Choice].self, from: data) {
            recents = saved
        }
    }

    // MARK: - Control

    func start(_ until: Until, keepsDisplayOn: Bool? = nil, onlyOnPower: Bool? = nil, announce: Bool = true) {
        let display = keepsDisplayOn ?? keepsDisplayOnByDefault
        let power = onlyOnPower ?? onlyOnPowerByDefault
        session = Session(until: until, keepsDisplayOn: display, onlyOnPower: power, startedAt: Date())
        if case .done = until { watcher = JobWatcher() }
        applyAssertion()
        showStatusItem()
        if announce { HUD.show(statusLine, symbol: symbol) }
        startWatching()
    }

    /// Starts a choice from the panel or a link and remembers it in Recent.
    func start(_ choice: Choice) {
        guard let until = choice.until(now: Date()) else { return }
        start(until)
        remember(choice)
    }

    /// Hyper+/ tap: start 12 hours; if on, stop; in the last five minutes, add an hour.
    func toggleDefault() {
        guard let session else {
            start(.date(Date().addingTimeInterval(Self.defaultDuration)))
            return
        }
        if session.warned, case .date = session.until {
            extend(by: 3600)
        } else {
            stop(reason: "Stopped.")
        }
    }

    /// Turns the screen off right away while the Mac stays awake (starting 12 hours if
    /// nothing is running). Better than dimming to zero: the panel actually powers down.
    func sleepDisplayNow() {
        if session == nil { start(.date(Date().addingTimeInterval(Self.defaultDuration)), keepsDisplayOn: false, announce: false) }
        if session?.keepsDisplayOn == true { setKeepsDisplayOn(false) }
        // Give the panel or pill a moment to disappear first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try? process.run()
        }
    }

    func stop(reason: String? = nil) {
        guard session != nil else { return }
        releaseAssertion()
        session = nil
        timer?.invalidate()
        timer = nil
        hideStatusItem()
        if let reason { HUD.show("Mac can sleep again · \(reason)", symbol: "moon.zzz") }
    }

    func extend(by seconds: TimeInterval) {
        guard let session else { return start(.date(Date().addingTimeInterval(seconds))) }
        let base: Date = if case let .date(end) = session.until, end > Date() { end } else { Date() }
        start(.date(base.addingTimeInterval(seconds)), keepsDisplayOn: session.keepsDisplayOn, onlyOnPower: session.onlyOnPower)
    }

    func setKeepsDisplayOn(_ on: Bool) {
        keepsDisplayOnByDefault = on
        guard session != nil else { return }
        session?.keepsDisplayOn = on
        applyAssertion()
        updateStatusItem()
    }

    func setOnlyOnPower(_ on: Bool) {
        onlyOnPowerByDefault = on
        guard session != nil else { return }
        session?.onlyOnPower = on
        check()
    }

    // MARK: - Assertion

    private func applyAssertion() {
        releaseAssertion()
        guard let session, !session.pausedOnBattery else { return }
        let type = session.keepsDisplayOn ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Keep Awake (Tweaks)" as CFString, &assertion) != kIOReturnSuccess {
            assertion = 0
        }
    }

    private func releaseAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
    }

    // MARK: - Watching

    private func startWatching() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    private func check() {
        guard var current = session else { return }
        let now = Date()
        let battery = Battery.current()

        var reason = Self.endReason(for: current.until, now: now,
                                    isRunning: { NSRunningApplication(processIdentifier: $0) != nil }, battery: battery)
        if reason == nil, case let .done(job) = current.until, watcher.isDone(job, now: now) {
            reason = job.finishedMessage
        }
        if let reason { return stop(reason: reason) }

        // Only while plugged in: let go on battery, take hold again on power.
        let shouldPause = current.onlyOnPower && battery.map { !$0.pluggedIn } == true
        if shouldPause != current.pausedOnBattery {
            current.pausedOnBattery = shouldPause
            session = current
            applyAssertion()
            HUD.show(shouldPause ? "On battery · Keep Awake paused" : "Plugged in · Keep Awake resumed",
                     symbol: shouldPause ? "pause.circle.fill" : symbol)
        }

        // Heads-up before a timed session ends.
        if case let .date(end) = current.until, !current.warned, end.timeIntervalSince(now) <= Self.warningLead {
            session?.warned = true
            HUD.show("Sleeping in \(max(1, Int(end.timeIntervalSince(now) / 60))) min · tap ⌃⌥⇧⌘/ to add an hour",
                     symbol: "hourglass", duration: 4)
        }
        updateStatusItem()
    }

    /// Why a session should end now, or nil to keep going. Job conditions are judged
    /// separately by `JobWatcher`.
    static func endReason(for until: Until, now: Date, isRunning: (pid_t) -> Bool, battery: Battery?) -> String? {
        if let battery, !battery.pluggedIn, battery.percent <= batteryFloor {
            return "battery is at \(battery.percent)%."
        }
        switch until {
        case .indefinitely, .done:
            return nil
        case let .date(end):
            return now >= end ? "the time you set is up." : nil
        case let .appQuits(pid, name):
            return isRunning(pid) ? nil : "\(name) quit."
        }
    }

    // MARK: - Recent choices

    private func remember(_ choice: Choice) {
        recents.removeAll { $0 == choice }
        recents.insert(choice, at: 0)
        recents = Array(recents.prefix(3))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "keepAwakeRecents")
        }
    }

    // MARK: - Labels

    /// The Keep Awake panel (hold Hyper+/, or click the menu bar cup).
    func showMenu() {
        KeepAwakePanelController.shared.toggle(self)
    }

    var statusLine: String {
        guard let session else { return "Not keeping awake" }
        let base: String = switch session.until {
        case .indefinitely: "Awake until you stop it"
        case let .date(end): "Awake until \(end.formatted(date: .omitted, time: .shortened))"
        case let .appQuits(_, name): "Awake until \(name) quits"
        case let .done(job): "Awake until \(job.untilPhrase)"
        }
        return session.pausedOnBattery ? "\(base) · paused on battery" : base
    }

    private var symbol: String {
        session?.keepsDisplayOn == true ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill"
    }

    /// "3h 12m", "45m", or a short word for open-ended sessions.
    static func countdown(until: Until, now: Date) -> String? {
        switch until {
        case let .date(end):
            let minutes = max(0, Int(end.timeIntervalSince(now) / 60))
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        case let .done(job):
            return job.shortLabel
        case .indefinitely, .appQuits:
            return nil
        }
    }

    /// Times worth offering: the next two whole hours, 5 and 6 PM if still ahead, and midnight.
    static func suggestedEndTimes(from now: Date, calendar: Calendar = .current) -> [Date] {
        var times: [Date] = []
        if let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) {
            times.append(nextHour)
            if let following = calendar.date(byAdding: .hour, value: 1, to: nextHour) { times.append(following) }
        }
        for hour in [17, 18] {
            if let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now), date > now { times.append(date) }
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) { times.append(midnight) }
        return Array(Set(times)).filter { $0.timeIntervalSince(now) >= 10 * 60 }.sorted()
    }

    /// Open apps, render apps first.
    static func candidateApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { lhs, rhs in
                let lAdobe = lhs.bundleIdentifier?.hasPrefix("com.adobe") == true
                let rAdobe = rhs.bundleIdentifier?.hasPrefix("com.adobe") == true
                if lAdobe != rAdobe { return lAdobe }
                return (lhs.localizedName ?? "") < (rhs.localizedName ?? "")
            }
    }

    // MARK: - Status item

    private func showStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.imagePosition = .imageLeading
            item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            statusItem = item
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let session else { return }
        let image = NSImage(systemSymbolName: session.pausedOnBattery ? "pause.circle" : symbol, accessibilityDescription: statusLine)
        image?.isTemplate = true
        button.image = image
        let text = showsCountdown ? Self.countdown(until: session.until, now: Date()) : nil
        button.title = text.map { " \($0)" } ?? ""
        button.imagePosition = text == nil ? .imageOnly : .imageLeading
        button.toolTip = statusLine
    }

    private func hideStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func statusItemClicked() {
        showMenu()
    }

    // MARK: - tweaks://awake links

    /// tweaks://awake?minutes=60 | ?hours=2 | ?until=18:30 | ?app=com.adobe.ame.application.26
    /// | ?done=render|downloads|upload|copy (&display=1&power=1), tweaks://awake/stop,
    /// tweaks://awake/toggle, tweaks://awake/menu
    func handle(_ url: URL) {
        guard url.scheme == "tweaks", url.host() == "awake" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func flag(_ name: String) -> Bool? { value(name).map { $0 == "1" || $0 == "true" } }
        let display = flag("display")
        let power = flag("power")

        switch url.path() {
        case "/stop": stop(reason: "Stopped.")
        case "/menu": showMenu()
        case "/toggle": toggleDefault()
        case "/screenoff": sleepDisplayNow()
        default:
            if let until = Self.until(minutes: value("minutes"), hours: value("hours"), time: value("until"), now: Date()) {
                start(until, keepsDisplayOn: display, onlyOnPower: power)
            } else if let job = value("done").flatMap(JobCondition.init(linkName:)) {
                start(.done(job), keepsDisplayOn: display, onlyOnPower: power)
            } else if let bundleID = value("app"),
                      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                start(.appQuits(pid: app.processIdentifier, name: app.localizedName ?? bundleID), keepsDisplayOn: display, onlyOnPower: power)
            } else {
                start(.date(Date().addingTimeInterval(Self.defaultDuration)), keepsDisplayOn: display, onlyOnPower: power)
            }
        }
    }

    static func until(minutes: String?, hours: String?, time: String?, now: Date, calendar: Calendar = .current) -> Until? {
        if let minutes = minutes.flatMap(Double.init), minutes > 0 { return .date(now.addingTimeInterval(minutes * 60)) }
        if let hours = hours.flatMap(Double.init), hours > 0 { return .date(now.addingTimeInterval(hours * 3600)) }
        if let time {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]),
                  var date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now)
            else { return nil }
            if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            return .date(date)
        }
        return nil
    }
}

/// A Keep Awake choice that can be remembered in Recent.
enum Choice: Codable, Hashable, Sendable {
    case hours(Double)
    case indefinitely
    case app(bundleID: String, name: String)
    case done(JobCondition)

    var title: String {
        switch self {
        case let .hours(hours): hours == 1 ? "1 hour" : "\(hours.formatted()) hours"
        case .indefinitely: "Indefinitely"
        case let .app(_, name): "Until \(name) quits"
        case let .done(job): job.title
        }
    }

    @MainActor
    func until(now: Date) -> KeepAwake.Until? {
        switch self {
        case let .hours(hours): .date(now.addingTimeInterval(hours * 3600))
        case .indefinitely: .indefinitely
        case let .done(job): .done(job)
        case let .app(bundleID, name):
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
                .map { .appQuits(pid: $0.processIdentifier, name: name) }
        }
    }
}

struct Battery: Equatable, Sendable {
    let percent: Int
    let pluggedIn: Bool

    static func current() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return Battery(percent: current * 100 / max, pluggedIn: state == kIOPSACPowerValue)
        }
        return nil
    }
}
