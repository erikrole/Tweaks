import AppKit
import CoreGraphics
import Darwin
import IOKit.pwr_mgt

/// Away mode's screen: the display never sleeps (so macOS never locks), but the built-in
/// panel fades to 0, external displays fade to black and the keyboard light goes off after
/// a short idle. Any input brings it back, including remote or agent control. Nothing
/// covers the screen, so screenshots still show the real desktop. The Mac stays unlocked
/// while this runs.
///
/// Safety rules: every level is saved (and persisted) before it is changed; a saved level
/// is only dropped once it has really been put back; the dimmer pauses for the lock
/// screen, fast user switching and sleep; and the user's own brightness change wins.
@MainActor
final class IdleDimmer {
    private(set) var isActive = false
    private(set) var isDimmed = false
    /// Locked, switched away from, or asleep: no dimming, no activity declarations.
    private(set) var isPaused = false

    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var activityAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var wakeWatch: Timer?
    private var fadeTimer: Timer?
    private var fadeStep = 0
    private var dimmedAt = Date.distantPast
    private var lastInput = Date()
    /// Original built-in levels, by display. Persisted until each one is back.
    private var savedBrightness: [CGDirectDisplayID: Float] = [:] {
        didSet { Self.persist(savedBrightness) }
    }
    /// What Tweaks last set, so a higher reading means the user raised it.
    private var lastSet: [CGDirectDisplayID: Float] = [:]
    private let keyboard = KeyboardBacklight()

    private static let restoreKey = "darkScreenRestoreBrightness"
    /// Idle this long before the screen dims.
    static let dimAfter: TimeInterval = 120
    /// How often idle is checked and macOS is told someone is here (its idle timers run in minutes).
    static let tickInterval: TimeInterval = 20
    /// While dimmed, how often input is looked for (catches typing without Accessibility).
    static let wakeCheckInterval: TimeInterval = 0.5
    static let fadeDuration: TimeInterval = 0.8
    private static let fadeSteps = 16

    /// `recover` is false for a second copy that's about to quit, so it can't undo the
    /// running copy's saved levels.
    init(recover: Bool = true) {
        guard recover else { return }
        restorePending(Self.loadPersisted())
        KeyboardBacklight.recover()
    }

    // MARK: - Lifecycle

    func start(dimNow: Bool = false) {
        if !isActive {
            isActive = true
            isPaused = false
            lastInput = Date()
            watchInput()
            watchSession()
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            declareActivity()
        }
        if dimNow {
            // Let the panel or pill fade first, and don't count the key that asked for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, !self.isPaused else { return }
                    self.lastInput = .distantPast
                    self.dim()
                }
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        observers.forEach { $0.0.removeObserver($0.1) }; observers = []
        undim()
        releaseActivity()
    }

    /// Lock screen, fast user switch or sleep: put everything back and stand down.
    private func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        undim()
        releaseActivity()
    }

    private func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        lastInput = Date()
        declareActivity()
    }

    // MARK: - Idle

    /// Seconds since any keyboard, mouse or trackpad input, from the window server. Needs
    /// no permission, so typing counts even without Accessibility.
    private static func systemIdle() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private var idle: TimeInterval {
        min(Date().timeIntervalSince(lastInput), Self.systemIdle())
    }

    private func tick() {
        guard isActive else { return }
        retryPendingRestores()
        guard !isPaused else { return }
        declareActivity() // keeps the screen saver, and its lock, from starting
        if isDimmed {
            if userRaisedBrightness() { inputArrived(); return }
            reapplyDim() // auto-brightness or a new display
        } else if idle >= Self.dimAfter {
            dim()
        }
    }

    private func declareActivity() {
        var id = activityAssertion
        if IOPMAssertionDeclareUserActivity("Away mode (Tweaks)" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            activityAssertion = id
        }
    }

    private func releaseActivity() {
        if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion) }
        activityAssertion = 0
    }

    private func watchInput() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .systemDefined, .leftMouseDown, .rightMouseDown,
                                           .otherMouseDown, .mouseMoved, .leftMouseDragged, .scrollWheel]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.inputArrived() }
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.inputArrived() }
        }) { monitors.append(global) }
    }

    private func watchSession() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (IdleDimmer) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
            observers.append((center, token))
        }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.pause() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.resume() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.pause() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume() }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.pause() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.resume() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { dimmer in
            dimmer.retryPendingRestores()
            if dimmer.isDimmed { dimmer.reapplyDim() }
        }
    }

    private func inputArrived() {
        guard isActive, !isPaused else { return }
        // Ignore the tail of the key or click that dimmed it.
        if isDimmed, Date() < dimmedAt.addingTimeInterval(0.5) { return }
        lastInput = Date()
        if isDimmed { undim() }
    }

    // MARK: - Built-in brightness (DisplayServices, private but long-stable)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = displayServices, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static var onlineDisplays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static var builtInDisplays: [CGDirectDisplayID] {
        onlineDisplays.filter { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard let get = symbol("DisplayServicesGetBrightness", as: GetBrightness.self) else { return nil }
        var level: Float = 0
        return get(id, &level) == 0 ? level : nil
    }

    @discardableResult
    private static func setBrightness(_ id: CGDirectDisplayID, _ level: Float) -> Bool {
        guard let set = symbol("DisplayServicesSetBrightness", as: SetBrightness.self) else { return false }
        return set(id, level) == 0
    }

    /// Saves (and persists) a built-in's level the first time Tweaks is about to lower it.
    private func saveLevel(_ id: CGDirectDisplayID) -> Bool {
        if savedBrightness[id] != nil { return true }
        guard let level = Self.brightness(id) else { return false }
        if level > 0.01 { savedBrightness[id] = level }
        return true
    }

    private func setDark(_ id: CGDirectDisplayID, _ level: Float) {
        // Never lower a panel whose level isn't safely recorded.
        guard saveLevel(id), Self.setBrightness(id, level) else { return }
        lastSet[id] = level
    }

    private func dim() {
        guard !isDimmed, !isPaused else { return }
        for id in Self.builtInDisplays { _ = saveLevel(id) }
        dimmedAt = Date()
        isDimmed = true
        keyboard.turnOff()
        fadeStep = 0
        let fade = Timer(timeInterval: Self.fadeDuration / Double(Self.fadeSteps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFade() }
        }
        RunLoop.main.add(fade, forMode: .common)
        fadeTimer = fade
        watchForWake()
    }

    private func advanceFade() {
        guard isDimmed else { fadeTimer?.invalidate(); fadeTimer = nil; return }
        fadeStep += 1
        let remaining = Float(max(0, Self.fadeSteps - fadeStep)) / Float(Self.fadeSteps)
        for id in Self.builtInDisplays {
            setDark(id, (savedBrightness[id] ?? 0) * remaining)
        }
        // External displays can't take a brightness; fading their gamma blacks them
        // without touching what screenshots capture. macOS resets it if Tweaks quits.
        for id in Self.onlineDisplays where CGDisplayIsBuiltin(id) == 0 {
            CGSetDisplayTransferByFormula(id, 0, remaining, 1, 0, remaining, 1, 0, remaining, 1)
        }
        if fadeStep >= Self.fadeSteps { fadeTimer?.invalidate(); fadeTimer = nil }
    }

    /// Re-darkens after auto-brightness or a newly connected display, saving first.
    private func reapplyDim() {
        guard isDimmed, fadeTimer == nil else { return }
        for id in Self.builtInDisplays { setDark(id, 0) }
        for id in Self.onlineDisplays where CGDisplayIsBuiltin(id) == 0 {
            CGSetDisplayTransferByFormula(id, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        }
        keyboard.turnOff()
    }

    /// Brightness keys or the Control Center slider moved a panel up while dark.
    private func userRaisedBrightness() -> Bool {
        guard fadeTimer == nil else { return false }
        for id in Self.builtInDisplays {
            if let now = Self.brightness(id), now > (lastSet[id] ?? 0) + 0.02 {
                // Their new level wins over the one saved before dimming.
                savedBrightness[id] = nil
                return true
            }
        }
        return false
    }

    /// While dark, look for input often: typing shows up here even without Accessibility.
    private func watchForWake() {
        wakeWatch?.invalidate()
        let watch = Timer(timeInterval: Self.wakeCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDimmed else { return }
                if Self.systemIdle() < Date().timeIntervalSince(self.dimmedAt) - 0.5 { self.inputArrived() }
            }
        }
        watch.tolerance = 0.2
        RunLoop.main.add(watch, forMode: .common)
        wakeWatch = watch
    }

    private func undim() {
        fadeTimer?.invalidate(); fadeTimer = nil
        wakeWatch?.invalidate(); wakeWatch = nil
        let wasDimmed = isDimmed
        isDimmed = false
        lastSet = [:]
        restorePending(savedBrightness)
        if wasDimmed { CGDisplayRestoreColorSyncSettings() }
        keyboard.restore()
    }

    // MARK: - Restore and recovery

    /// Puts levels back; anything that can't be restored yet (lid closed, display
    /// offline) stays saved and is retried on display changes, ticks and next launch.
    private func restorePending(_ levels: [CGDirectDisplayID: Float]) {
        let online = Set(Self.builtInDisplays)
        var remaining = levels
        for (id, level) in levels where online.contains(id) && Self.setBrightness(id, level) {
            remaining[id] = nil
        }
        savedBrightness = remaining
    }

    private func retryPendingRestores() {
        guard !isDimmed, !savedBrightness.isEmpty else { return }
        restorePending(savedBrightness)
    }

    private static func persist(_ levels: [CGDirectDisplayID: Float]) {
        if levels.isEmpty { UserDefaults.standard.removeObject(forKey: restoreKey); return }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: levels.map { (String($0.key), $0.value) }), forKey: restoreKey)
    }

    private static func loadPersisted() -> [CGDirectDisplayID: Float] {
        let defaults = UserDefaults.standard
        if let stored = defaults.dictionary(forKey: restoreKey) as? [String: Float] {
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, level in UInt32(key).map { ($0, level) } })
        }
        // Older builds stored one level for every built-in display.
        if let level = defaults.object(forKey: restoreKey) as? Float, level > 0 {
            return Dictionary(uniqueKeysWithValues: builtInDisplays.map { ($0, level) })
        }
        return [:]
    }
}

/// The keyboard backlight, through CoreBrightness's KeyboardBrightnessClient (private but
/// long-stable). Changes aren't committed, so the saved preference stays as you set it.
@MainActor
private final class KeyboardBacklight {
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Set = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool

    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
    private static let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")

    private lazy var client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = type.init()
        let needed = [Self.getSelector, Self.setSelector, Self.idsSelector]
        return needed.allSatisfy { client.responds(to: $0) } ? client : nil
    }()

    private var saved: [UInt64: Float] = [:] {
        didSet { Self.persist(saved) }
    }

    /// Saved so a quit, crash or reinstall while dimmed doesn't leave the keyboard dark.
    private static let restoreKey = "darkScreenRestoreKeyboard"

    private static func persist(_ levels: [UInt64: Float]) {
        if levels.isEmpty { UserDefaults.standard.removeObject(forKey: restoreKey); return }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: levels.map { (String($0.key), $0.value) }), forKey: restoreKey)
    }

    /// Restores levels left behind by a previous run.
    static func recover() {
        guard let stored = UserDefaults.standard.dictionary(forKey: restoreKey) as? [String: Float], !stored.isEmpty else { return }
        let backlight = KeyboardBacklight()
        backlight.saved = Dictionary(uniqueKeysWithValues: stored.compactMap { key, level in UInt64(key).map { ($0, level) } })
        backlight.restore()
    }

    private var ids: [UInt64] {
        guard let client else { return [] }
        let list = client.perform(Self.idsSelector)?.takeRetainedValue() as? [NSNumber]
        return list?.map(\.uint64Value) ?? []
    }

    func turnOff() {
        guard let client else { return }
        let get = unsafeBitCast(client.method(for: Self.getSelector), to: Get.self)
        let set = unsafeBitCast(client.method(for: Self.setSelector), to: Set.self)
        for id in ids {
            if saved[id] == nil {
                let level = get(client, Self.getSelector, id)
                if level > 0.01 { saved[id] = level }
            }
            _ = set(client, Self.setSelector, 0, 500, false, id)
        }
    }

    func restore() {
        guard let client, !saved.isEmpty else { return }
        let set = unsafeBitCast(client.method(for: Self.setSelector), to: Set.self)
        let present = Swift.Set(ids)
        var remaining = saved
        for (id, level) in saved where present.contains(id) && set(client, Self.setSelector, level, 0, false, id) {
            remaining[id] = nil
        }
        saved = remaining
    }
}
