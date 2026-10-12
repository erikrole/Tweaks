import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// A smarter caffeinate. Tap Hyper+/ (⌃⌥⇧⌘/) for 12 hours (tap again to stop); hold it
/// for a menu at the pointer: a while, until a time, until an app quits, or until you stop it. While a session runs, a
/// cup in the menu bar shows what it's waiting for, with Extend and Stop. It also answers
/// tweaks://awake links, so Raycast Quicklinks can drive it.
@MainActor
@Observable
final class KeepAwake {
    enum Until: Equatable {
        case indefinitely
        case date(Date)
        case appQuits(pid: pid_t, name: String)
    }

    struct Session: Equatable {
        var until: Until
        var keepsDisplayOn: Bool
        let startedAt: Date
    }

    private(set) var session: Session?
    var keepsDisplayOnByDefault: Bool {
        didSet { UserDefaults.standard.set(keepsDisplayOnByDefault, forKey: "keepAwakeDisplayOn") }
    }

    /// Ends a session on battery at or below this, so a forgotten one can't drain the Mac.
    static let batteryFloor = 15

    private var assertion: IOPMAssertionID = 0
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    init() {
        keepsDisplayOnByDefault = UserDefaults.standard.bool(forKey: "keepAwakeDisplayOn")
    }

    // MARK: - Control

    func start(_ until: Until, keepsDisplayOn: Bool? = nil) {
        let display = keepsDisplayOn ?? keepsDisplayOnByDefault
        release()
        let type = display ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        let reason = "Keep Awake (Tweaks)" as CFString
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess else {
            assertion = 0
            return
        }
        session = Session(until: until, keepsDisplayOn: display, startedAt: Date())
        showStatusItem()
        startWatching()
    }

    /// Hyper+/ tap: start the default 12 hours, or stop if already on.
    static let defaultDuration: TimeInterval = 12 * 3600

    func toggleDefault() {
        if session == nil {
            start(.date(Date().addingTimeInterval(Self.defaultDuration)))
            Notifier.post(title: "Keeping your Mac awake for 12 hours", body: "Tap ⌃⌥⇧⌘/ again to stop, or hold it for more options.")
        } else {
            stop(reason: "Stopped with ⌃⌥⇧⌘/.")
        }
    }

    func stop(reason: String? = nil) {
        guard session != nil else { return }
        release()
        session = nil
        timer?.invalidate()
        timer = nil
        hideStatusItem()
        if let reason { Notifier.post(title: "Your Mac can sleep again", body: reason) }
    }

    func extend(by seconds: TimeInterval) {
        guard let session else { return start(.date(Date().addingTimeInterval(seconds))) }
        let base: Date = if case let .date(end) = session.until, end > Date() { end } else { Date() }
        start(.date(base.addingTimeInterval(seconds)), keepsDisplayOn: session.keepsDisplayOn)
    }

    func setKeepsDisplayOn(_ on: Bool) {
        keepsDisplayOnByDefault = on
        guard let session else { return }
        start(session.until, keepsDisplayOn: on)
    }

    private func release() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
    }

    // MARK: - Watching for the end

    private func startWatching() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    private func check() {
        guard let session else { return }
        if let reason = Self.endReason(for: session.until, now: Date(), isRunning: { NSRunningApplication(processIdentifier: $0) != nil },
                                       battery: Battery.current()) {
            stop(reason: reason)
        } else {
            updateStatusItem()
        }
    }

    /// Why a session should end now, or nil to keep going.
    static func endReason(for until: Until, now: Date, isRunning: (pid_t) -> Bool, battery: Battery?) -> String? {
        if let battery, !battery.pluggedIn, battery.percent <= batteryFloor {
            return "Stopped keeping it awake: battery is at \(battery.percent)%."
        }
        switch until {
        case .indefinitely:
            return nil
        case let .date(end):
            return now >= end ? "The time you set is up." : nil
        case let .appQuits(pid, name):
            return isRunning(pid) ? nil : "\(name) quit."
        }
    }

    // MARK: - Menus

    /// The hot key menu, at the pointer.
    func showMenu() {
        NSApp.activate()
        let menu = session == nil ? startMenu() : activeMenu()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func startMenu() -> NSMenu {
        let menu = NSMenu(title: "Keep Awake")
        menu.addItem(header("Keep your Mac awake"))
        for (title, minutes) in [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240)] {
            menu.addItem(action(title) { $0.start(.date(Date().addingTimeInterval(TimeInterval(minutes) * 60))) })
        }
        let untilItem = NSMenuItem(title: "Until…", action: nil, keyEquivalent: "")
        let untilMenu = NSMenu()
        for date in Self.suggestedEndTimes(from: Date()) {
            untilMenu.addItem(action(date.formatted(date: .omitted, time: .shortened)) { $0.start(.date(date)) })
        }
        untilItem.submenu = untilMenu
        menu.addItem(untilItem)

        let appItem = NSMenuItem(title: "Until an App Quits", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        for app in Self.candidateApps() {
            let item = action(app.localizedName ?? "App") { $0.start(.appQuits(pid: app.processIdentifier, name: app.localizedName ?? "The app")) }
            item.image = app.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            appMenu.addItem(item)
        }
        if appMenu.items.isEmpty { appMenu.addItem(NSMenuItem(title: "No apps open", action: nil, keyEquivalent: "")) }
        appItem.submenu = appMenu
        menu.addItem(appItem)

        menu.addItem(action("Indefinitely") { $0.start(.indefinitely) })
        menu.addItem(.separator())
        let display = action("Keep the Display On Too") { $0.keepsDisplayOnByDefault.toggle() }
        display.state = keepsDisplayOnByDefault ? .on : .off
        menu.addItem(display)
        return menu
    }

    private func activeMenu() -> NSMenu {
        let menu = NSMenu(title: "Keep Awake")
        menu.addItem(header(statusLine))
        menu.addItem(.separator())
        menu.addItem(action("Add 30 Minutes") { $0.extend(by: 30 * 60) })
        menu.addItem(action("Add 1 Hour") { $0.extend(by: 60 * 60) })
        let display = action("Keep the Display On") { $0.setKeepsDisplayOn(!($0.session?.keepsDisplayOn ?? false)) }
        display.state = session?.keepsDisplayOn == true ? .on : .off
        menu.addItem(display)
        menu.addItem(.separator())
        menu.addItem(action("Stop Keeping Awake") { $0.stop() })
        return menu
    }

    var statusLine: String {
        guard let session else { return "Not keeping awake" }
        switch session.until {
        case .indefinitely: return "Awake until you stop it"
        case let .date(end): return "Awake until \(end.formatted(date: .omitted, time: .shortened))"
        case let .appQuits(_, name): return "Awake until \(name) quits"
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
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            statusItem = item
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        let image = NSImage(systemSymbolName: session?.keepsDisplayOn == true ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill",
                            accessibilityDescription: statusLine)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = statusLine
    }

    private func hideStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        let menu = activeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: - tweaks://awake links

    /// tweaks://awake?minutes=60 | ?hours=2 | ?until=18:30 | ?app=com.adobe.ame.application.26
    /// (&display=1), tweaks://awake/stop, tweaks://awake/toggle, tweaks://awake/menu
    func handle(_ url: URL) {
        guard url.scheme == "tweaks", url.host() == "awake" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let display = value("display").map { $0 == "1" || $0 == "true" }

        switch url.path() {
        case "/stop": stop()
        case "/menu": showMenu()
        case "/toggle": session == nil ? start(.indefinitely, keepsDisplayOn: display) : stop()
        default:
            if let until = Self.until(minutes: value("minutes"), hours: value("hours"), time: value("until"), now: Date()) {
                start(until, keepsDisplayOn: display)
            } else if let bundleID = value("app"),
                      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                start(.appQuits(pid: app.processIdentifier, name: app.localizedName ?? bundleID), keepsDisplayOn: display)
            } else {
                start(.indefinitely, keepsDisplayOn: display)
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

    // MARK: - Menu helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ handler: @escaping @MainActor (KeepAwake) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak self] in
            guard let self else { return }
            handler(self)
        }
        return item
    }
}

/// An NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() {
        handler()
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
