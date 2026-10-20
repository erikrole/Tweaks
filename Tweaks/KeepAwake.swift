import AppKit
import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// IOPS signals this on the main run loop, which is where `KeepAwake` runs.
/// The pointer isn't Sendable, so only its bits cross into the main-actor closure.
private func keepAwakePowerChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let bits = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        guard let context = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        Unmanaged<KeepAwake>.fromOpaque(context).takeUnretainedValue().check()
    }
}

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
        /// Away mode: the display never sleeps (so no lock) but dims when idle.
        var dimsWhenIdle = false
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
            armCountdown()
        }
    }
    /// Recent choices, newest first, shown at the top of the panel.
    private(set) var recents: [Choice] = []

    /// Ends a session on battery at or below this, so a forgotten one can't drain the Mac.
    static let batteryFloor = 15
    /// The heads-up comes this long before a timed session ends.
    static let warningLead: TimeInterval = 5 * 60
    static let defaultDuration: TimeInterval = 12 * 3600

    /// How often a render, upload, or NAS-copy session samples the job. Those quiet
    /// periods are one to three minutes, so a tighter loop only costs wakeups.
    /// Tolerance is wide on purpose: a late sample ends the session late, not early.
    static let watchInterval: TimeInterval = 60
    static let watchTolerance: TimeInterval = 30
    /// Downloads-folder events arrive in bursts. One look a few seconds later is enough.
    static let downloadDebounce: TimeInterval = 5

    /// How a running session is followed. Timed and open-ended sessions wait on the
    /// clock, power-source changes, or the app quitting. Downloads wait on the folder.
    enum Follow: Equatable {
        case events
        /// Samples at `watchInterval`, with `watchTolerance` of slop.
        case samples
    }

    static func follow(_ until: Until) -> Follow {
        switch until {
        case .done(.render), .done(.upload), .done(.nasCopy):
            .samples
        case .done(.downloads), .indefinitely, .date, .appQuits:
            .events
        }
    }

    private var assertion: IOPMAssertionID = 0
    private var statusItem: NSStatusItem?
    private var deadlineTimer: Timer?
    private var warningTimer: Timer?
    private var countdownTimer: Timer?
    private var jobTimer: Timer?
    private var jobTimerInterval: TimeInterval?
    private var downloadSource: DispatchSourceFileSystemObject?
    private var downloadDebounceWork: DispatchWorkItem?
    /// Removed in `deinit`. `stop()` can run from the IOPS callback, so the source stays in place until this object is released.
    @ObservationIgnored nonisolated(unsafe) private var powerSource: CFRunLoopSource?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var watcher = JobWatcher()
    @ObservationIgnored private let dimmer = IdleDimmer()

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

    deinit {
        guard let source = powerSource else { return }
        CFRunLoopSourceInvalidate(source)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = nil
    }

    // MARK: - Control

    func start(_ until: Until, keepsDisplayOn: Bool? = nil, onlyOnPower: Bool? = nil, dimsWhenIdle: Bool = false,
               announce: Bool = true) {
        let display = dimsWhenIdle || (keepsDisplayOn ?? keepsDisplayOnByDefault)
        let power = onlyOnPower ?? onlyOnPowerByDefault
        session = Session(until: until, keepsDisplayOn: display, onlyOnPower: power, dimsWhenIdle: dimsWhenIdle, startedAt: Date())
        if case .done = until { watcher = JobWatcher() }
        applyAssertion()
        if dimsWhenIdle { dimmer.start() } else { dimmer.stop() }
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
            startAway()
            return
        }
        if session.warned, case .date = session.until {
            extend(by: 3600)
        } else {
            stop(reason: "Stopped.")
        }
    }

    /// Away: the Mac stays awake and never locks, so you (and agents) can always get in.
    /// The built-in screen dims after a couple of idle minutes and wakes on any input.
    func startAway(dimNow: Bool = false) {
        start(.indefinitely, dimsWhenIdle: true, announce: !dimNow)
        dimmer.start(dimNow: dimNow)
    }

    /// Screen stays on, for renders and anything you want to watch.
    func startScreenOn() {
        start(.indefinitely, keepsDisplayOn: true)
    }

    /// Dims the screen now and keeps the Mac awake and unlocked (Away mode).
    func sleepDisplayNow() {
        if session?.dimsWhenIdle == true { dimmer.start(dimNow: true) } else { startAway(dimNow: true) }
    }

    func stop(reason: String? = nil) {
        dimmer.stop()
        guard session != nil else { return }
        releaseAssertion()
        session = nil
        stopSessionTimers()
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

    /// No repeating poll for a timed, indefinite, or "until this app quits" session.
    /// The end and the five-minute warning are one-shot timers. Battery and plug
    /// changes arrive from IOPS. Downloads watch the folder. Render, upload, and
    /// NAS copy still sample, slowly, because CPU, byte counters, and open files
    /// don't post an event when they go idle.
    private func startWatching() {
        observePower()
        observeWorkspace()
        armSessionClocks()
        armJobWatch()
        check()
    }

    private func stopSessionTimers() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        warningTimer?.invalidate()
        warningTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        stopJobSampling()
    }

    private func observePower() {
        guard powerSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The source is added to the main run loop below, so the callback is already on this actor.
        guard let created = IOPSNotificationCreateRunLoopSource(keepAwakePowerChanged, context) else { return }
        let source = created.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        if terminateObserver == nil {
            terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let until = self.session?.until else { return }
                    switch until {
                    case .appQuits, .done(.render): self.check()
                    default: break
                    }
                }
            }
        }
        if launchObserver == nil {
            // aerender is not always an application launch. The sample timer still sees it.
            // Notification and NSRunningApplication aren't Sendable; the path string is.
            launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let path = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.executableURL?.path ?? ""
                guard CPUSampler.shouldMeasure(path) else { return }
                MainActor.assumeIsolated {
                    guard let self, case .done(.render) = self.session?.until else { return }
                    self.check()
                }
            }
        }
    }

    private func armSessionClocks() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        warningTimer?.invalidate()
        warningTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard let session, case let .date(end) = session.until else { return }
        let now = Date()
        if !session.warned {
            let warnAt = end.addingTimeInterval(-Self.warningLead)
            if warnAt > now { warningTimer = oneShot(at: warnAt, tolerance: 0) }
        }
        if end > now { deadlineTimer = oneShot(at: end, tolerance: 0) }
        armCountdown()
    }

    /// One-shots can arrive a moment early. Arm again if the moment they guard is still ahead,
    /// so a session can't miss its warning or run on past the time you set.
    private func ensureDateClocks() {
        guard let session, case let .date(end) = session.until else { return }
        let now = Date()
        if end > now, deadlineTimer?.isValid != true {
            deadlineTimer = oneShot(at: end, tolerance: 0)
        }
        if !session.warned {
            let warnAt = end.addingTimeInterval(-Self.warningLead)
            if warnAt > now, warningTimer?.isValid != true {
                warningTimer = oneShot(at: warnAt, tolerance: 0)
            }
        }
    }

    /// The cup shows minutes, so it only needs to move about once a minute.
    private func armCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        guard showsCountdown, let session, case .date = session.until else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        timer.tolerance = 10
        let intoMinute = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        timer.fireDate = Date().addingTimeInterval(max(1, 60 - intoMinute))
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func oneShot(at date: Date, tolerance: TimeInterval) -> Timer {
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func armJobWatch() {
        guard let until = session?.until else {
            stopJobSampling()
            return
        }
        switch until {
        case .done(.downloads):
            startDownloadSourceIfNeeded()
        case .done:
            stopDownloadSource()
        default:
            stopJobSampling()
        }
    }

    private func armJobFollowUp() {
        guard let until = session?.until else { return }
        switch Self.follow(until) {
        case .samples:
            armSampleTimer()
        case .events:
            guard case .done(.downloads) = until else { return }
            if downloadSource != nil {
                armDownloadQuietDeadline()
            } else {
                armSampleTimer()
            }
        }
    }

    private func armSampleTimer() {
        guard jobTimerInterval != Self.watchInterval else { return }
        jobTimer?.invalidate()
        let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = Self.watchTolerance
        RunLoop.main.add(timer, forMode: .common)
        jobTimer = timer
        jobTimerInterval = Self.watchInterval
    }

    /// One wake when the quiet period is up. Folder events cover the job starting again before then.
    private func armDownloadQuietDeadline() {
        jobTimer?.invalidate()
        jobTimer = nil
        jobTimerInterval = nil
        guard let since = watcher.quietSince else { return }
        let fire = since.addingTimeInterval(JobCondition.downloads.quietPeriod)
        guard fire > Date() else { return }
        jobTimer = oneShot(at: fire, tolerance: 0)
    }

    private func startDownloadSourceIfNeeded() {
        guard downloadSource == nil else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            DownloadsAccessAlert.showOnce()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleDownloadCheck() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        downloadSource = source
    }

    private func scheduleDownloadCheck() {
        guard case .done(.downloads) = session?.until else { return }
        downloadDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        downloadDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.downloadDebounce, execute: work)
    }

    private func stopDownloadSource() {
        downloadDebounceWork?.cancel()
        downloadDebounceWork = nil
        downloadSource?.cancel()
        downloadSource = nil
    }

    private func stopJobSampling() {
        jobTimer?.invalidate()
        jobTimer = nil
        jobTimerInterval = nil
        stopDownloadSource()
    }

    /// File-visible: the IOPS callback sits above this type, and `private` stops at the type.
    fileprivate func check() {
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
        ensureDateClocks()
        armJobFollowUp()
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
        if session.until == .indefinitely {
            let mode = session.dimsWhenIdle ? "Away · awake and unlocked, screen dims" : (session.keepsDisplayOn ? "Screen stays on" : "Awake until you stop it")
            return session.pausedOnBattery ? "\(mode) · paused on battery" : mode
        }
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
        case "/dark": sleepDisplayNow()
        case "/away": startAway()
        case "/screenon": startScreenOn()
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
