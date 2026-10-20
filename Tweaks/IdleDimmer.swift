import AppKit
import Darwin
import IOKit.pwr_mgt

/// Away mode's screen: the display never sleeps (so macOS never locks), but the built-in
/// panel dims to 0 after a short idle and comes back on any key or mouse input, including
/// input from remote or agent control. Nothing covers the screen, so screenshots still
/// show the real desktop. The Mac stays unlocked while this runs.
@MainActor
final class IdleDimmer {
    private(set) var isActive = false
    private(set) var isDimmed = false

    private var monitors: [Any] = []
    private var activityAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var lastInput = Date()
    private var savedBrightness: [CGDirectDisplayID: Float] = [:]

    /// Saved so a crash or quit while dimmed doesn't leave the built-in panel at 0.
    private static let restoreKey = "darkScreenRestoreBrightness"
    /// Idle this long before the screen dims.
    static let dimAfter: TimeInterval = 120
    /// How often idle is checked and macOS is told someone is here (its idle timers run in minutes).
    static let tickInterval: TimeInterval = 20

    init() {
        Self.recoverBrightness()
    }

    func start(dimNow: Bool = false) {
        if !isActive {
            isActive = true
            lastInput = Date()
            watchInput()
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
                    guard let self, self.isActive else { return }
                    self.lastInput = .distantPast
                    self.dim()
                }
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        undim()
        if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion) }
        activityAssertion = 0
    }

    private func tick() {
        guard isActive else { return }
        declareActivity() // keeps the screen saver, and its lock, from starting
        if Date().timeIntervalSince(lastInput) >= Self.dimAfter {
            dim() // also re-applies 0 if auto-brightness raised it
        }
    }

    private func declareActivity() {
        var id = activityAssertion
        if IOPMAssertionDeclareUserActivity("Away mode (Tweaks)" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            activityAssertion = id
        }
    }

    private func watchInput() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .mouseMoved, .leftMouseDragged, .scrollWheel]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.inputArrived() }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.inputArrived() }
        }) {
            monitors.append(global)
        }
    }

    private func inputArrived() {
        guard isActive else { return }
        // Ignore the tail of the key or click that dimmed it.
        if isDimmed, Date() < dimmedAt.addingTimeInterval(0.5) { return }
        lastInput = Date()
        if isDimmed { undim() }
    }

    private var dimmedAt = Date.distantPast

    // MARK: - Built-in brightness (DisplayServices, private but long-stable)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = displayServices, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static var builtInDisplays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }

    private func dim() {
        guard let get = Self.symbol("DisplayServicesGetBrightness", as: GetBrightness.self),
              let set = Self.symbol("DisplayServicesSetBrightness", as: SetBrightness.self) else { return }
        for id in Self.builtInDisplays {
            if savedBrightness[id] == nil {
                var level: Float = 0
                if get(id, &level) == 0, level > 0.01 { savedBrightness[id] = level }
            }
            _ = set(id, 0)
        }
        if !isDimmed { dimmedAt = Date() }
        isDimmed = true
        if let level = savedBrightness.values.first {
            UserDefaults.standard.set(level, forKey: Self.restoreKey)
        }
    }

    private func undim() {
        if let set = Self.symbol("DisplayServicesSetBrightness", as: SetBrightness.self) {
            for (id, level) in savedBrightness { _ = set(id, level) }
        }
        savedBrightness = [:]
        isDimmed = false
        UserDefaults.standard.removeObject(forKey: Self.restoreKey)
    }

    private static func recoverBrightness() {
        let defaults = UserDefaults.standard
        guard let level = defaults.object(forKey: restoreKey) as? Float, level > 0,
              let set = symbol("DisplayServicesSetBrightness", as: SetBrightness.self) else { return }
        for id in builtInDisplays { _ = set(id, level) }
        defaults.removeObject(forKey: restoreKey)
    }
}
