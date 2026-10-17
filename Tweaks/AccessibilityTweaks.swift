import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Accessibility helpers

enum AX {
    /// Whether Tweaks may use Accessibility. AXIsProcessTrusted() can keep answering
    /// "no" for a while after you switch Tweaks on in System Settings, so also try a
    /// harmless real call: if the system answers it, the permission is there.
    static var isTrusted: Bool {
        if AXIsProcessTrusted() { return true }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        return result == .success || result == .noValue
    }

    /// Relaunches Tweaks: the reliable way to pick up a permission macOS cached as "no".
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? process.run()
        AppDelegate.reallyQuit = true
        NSApp.terminate(nil)
    }

    /// Shows macOS's "allow Tweaks to control your computer" prompt if needed.
    static func requestTrust() {
        // The documented value of kAXTrustedCheckOptionPrompt, spelled out because the
        // imported global isn't concurrency-safe under Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
}

// MARK: - Notifications

/// Finds notification banners and alerts in Notification Center's accessibility tree and
/// closes them. On macOS 26 each one is an AXGroup with a Notification Center subrole and
/// a "Close" action; its description starts with the sending app's name.
enum NotificationCloser {
    static let notificationSubroles: Set<String> = [
        "AXNotificationCenterBanner", "AXNotificationCenterAlert",
        "AXNotificationCenterBannerStack", "AXNotificationCenterAlertStack",
    ]

    struct Notification {
        let element: AXUIElement
        let summary: String
        let closeAction: String?
    }

    static func visibleNotifications() -> [Notification] {
        guard let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return [] }
        let app = AXUIElementCreateApplication(center.processIdentifier)
        var found: [Notification] = []
        for window in AX.children(app) where (AX.attribute(window, kAXRoleAttribute) as String?) == kAXWindowRole {
            collect(window, depth: 0, into: &found)
        }
        return found
    }

    private static func collect(_ element: AXUIElement, depth: Int, into found: inout [Notification]) {
        guard depth < 10 else { return }
        if let subrole: String = AX.attribute(element, kAXSubroleAttribute), notificationSubroles.contains(subrole) {
            let actions = AX.actions(element)
            found.append(Notification(
                element: element,
                summary: AX.attribute(element, kAXDescriptionAttribute) ?? "",
                closeAction: closeAction(in: actions)
            ))
            return
        }
        for child in AX.children(element) { collect(child, depth: depth + 1, into: &found) }
    }

    /// Picks "Clear All" for a stack, else "Close". Action names look like "Name:Close\nTarget:…".
    static func closeAction(in actions: [String]) -> String? {
        actions.first { $0.hasPrefix("Name:Clear All") } ?? actions.first { $0.hasPrefix("Name:Close") }
    }

    /// Closes everything on screen. Stacks reveal more notifications as they're cleared,
    /// so it repeats a few times.
    @discardableResult
    static func closeAll() -> Int {
        var closed = 0
        for _ in 0..<8 {
            let notifications = visibleNotifications().filter { $0.closeAction != nil }
            guard !notifications.isEmpty else { break }
            for notification in notifications {
                if let action = notification.closeAction,
                   AXUIElementPerformAction(notification.element, action as CFString) == .success {
                    closed += 1
                }
            }
        }
        return closed
    }

    /// True for the banner Shortcuts shows while a shortcut runs.
    static func isShortcutRunning(_ summary: String) -> Bool {
        let lower = summary.lowercased()
        return lower.hasPrefix("shortcuts") && (lower.contains("running") || lower.contains("is running"))
    }
}

/// Registers a system-wide hot key with Carbon, which needs no extra permission.
/// Reports both press and release, so callers can tell a tap from a hold.
@MainActor
final class HotKey {
    /// ⌃⌥⇧⌘, the "Hyper" key.
    static let hyper = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    private var reference: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var pressed: [UInt32: () -> Void] = [:]
    private static var released: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private(set) var registrationStatus: OSStatus = noErr

    static func failureMessage(status: OSStatus) -> String? {
        status == noErr ? nil : "Shortcut unavailable (macOS error \(status)). Choose different keys; another app or macOS may be using these."
    }

    init(keyCode: UInt32, modifiers: UInt32 = HotKey.hyper,
         onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        id = Self.nextID
        Self.nextID += 1
        registrationStatus = Self.installHandlerOnce()
        guard registrationStatus == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5457_4B53), id: id) // "TWKS"
        registrationStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if registrationStatus == noErr {
            Self.pressed[id] = onPress
            Self.released[id] = onRelease
        }
    }

    /// One Carbon handler for every hot key, dispatching by id, so each event runs
    /// exactly one action.
    private static func installHandlerOnce() -> OSStatus {
        guard handler == nil else { return noErr }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    (isPress ? HotKey.pressed[id] : HotKey.released[id])?()
                }
            }
            return noErr
        }, 2, &eventTypes, nil, &handler)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.pressed[id] = nil
        Self.released[id] = nil
    }
}

/// Tells a quick tap from a press-and-hold on a hot key.
@MainActor
final class TapOrHold {
    static let holdDelay: TimeInterval = 0.35
    private var timer: Timer?
    private var heldFired = false
    private let onTap: () -> Void
    private let onHold: () -> Void

    init(onTap: @escaping () -> Void, onHold: @escaping () -> Void) {
        self.onTap = onTap
        self.onHold = onHold
    }

    func pressed() {
        heldFired = false
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.heldFired = true
                self.onHold()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func released() {
        timer?.invalidate()
        timer = nil
        if !heldFired { onTap() }
        heldFired = false
    }
}

/// Watches for the "Shortcut is running" banner and closes it as soon as it appears.
@MainActor
final class ShortcutBannerDismisser {
    /// Walking Notification Center's accessibility tree is the expensive part. Most of the
    /// time Shortcuts isn't running, and then there is nothing to close.
    static let pollInterval: TimeInterval = 3
    static let shortcutBundleIDs: Set<String> = [
        "com.apple.shortcuts",
        "com.apple.shortcuts.events",
        "com.apple.shortcuts.ShortcutsViewService",
    ]

    private var timer: Timer?

    static func shortcutsMightBeRunning(_ apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> Bool {
        apps.contains { $0.bundleIdentifier.map(shortcutBundleIDs.contains) == true }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AX.isTrusted, Self.shortcutsMightBeRunning() else { return }
                for notification in NotificationCloser.visibleNotifications()
                where NotificationCloser.isShortcutRunning(notification.summary) {
                    if let action = notification.closeAction {
                        AXUIElementPerformAction(notification.element, action as CFString)
                    }
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Green button

/// Turns a click on a window's green button into "fill the screen" (without macOS full
/// screen); a second click restores the window. Holding ⌥ keeps the normal behaviour.
@MainActor
final class GreenButtonFill {
    private struct SavedWindow {
        let element: AXUIElement
        let frame: CGRect
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var savedFrames: [String: SavedWindow] = [:]
    private var swallowNextMouseUp = false
    fileprivate static weak var current: GreenButtonFill?

    enum FillDecision: Equatable {
        /// Save the window's current frame, then move it to the visible frame.
        case fill(save: CGRect)
        /// Put the window back where it was before it was filled.
        case restore(CGRect)
    }

    static func decision(frame: CGRect, target: CGRect, saved: CGRect?) -> FillDecision {
        if approximatelyEqual(frame, target), let saved {
            return .restore(saved)
        }
        return .fill(save: frame)
    }

    func start() {
        guard tap == nil, AX.isTrusted else { return }
        Self.current = self
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: greenButtonCallback, userInfo: nil
        )
        guard let tap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        swallowNextMouseUp = false
        if Self.current === self { Self.current = nil }
        let saved = savedFrames
        savedFrames = [:]
        for window in saved.values {
            Self.setFrame(window.frame, of: window.element)
        }
    }

    /// Returns true when the event was handled and should be swallowed.
    fileprivate func handle(_ type: CGEventType, location: CGPoint, optionDown: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The matching mouse-up may never come; don't swallow some later click's.
            swallowNextMouseUp = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if type == .leftMouseUp, swallowNextMouseUp {
            swallowNextMouseUp = false
            return true
        }
        guard type == .leftMouseDown else { return false }
        swallowNextMouseUp = false
        // Every click on the Mac passes through here, so rule most out without asking
        // any app anything: the green button sits in a window's top-left corner.
        guard Self.isNearWindowCorner(location) else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        // A busy app (After Effects mid-render) answers slowly; don't hold the click.
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &hit) == .success,
              let button = hit,
              let subrole: String = AX.attribute(button, kAXSubroleAttribute),
              [kAXFullScreenButtonSubrole as String, kAXZoomButtonSubrole as String].contains(subrole),
              let window: AXUIElement = AX.attribute(button, kAXWindowAttribute)
        else { return false }

        if optionDown {
            // Passing Option through invokes native Zoom, not full screen.
            guard Self.toggleFullScreen(window) else { return false }
        } else {
            toggleFill(window)
        }
        swallowNextMouseUp = true
        return true
    }

    static func toggleFullScreen(_ window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.2)
        let attribute = "AXFullScreen" as CFString
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, attribute, &settable) == .success,
              settable.boolValue, let current: Bool = AX.attribute(window, "AXFullScreen") else { return false }
        return AXUIElementSetAttributeValue(window, attribute, (!current ? kCFBooleanTrue : kCFBooleanFalse)) == .success
    }

    /// True when the point is in the title-bar corner of an on-screen app window,
    /// checked from the window server's list with no call into the app.
    static func isNearWindowCorner(_ point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.contains(point)
            else { continue }
            // The frontmost window under the point decides.
            return isInCorner(point, of: bounds)
        }
        return false
    }

    static func isInCorner(_ point: CGPoint, of bounds: CGRect) -> Bool {
        point.x - bounds.minX <= 90 && point.y - bounds.minY <= 40
    }

    private func toggleFill(_ window: AXUIElement) {
        guard let frame = Self.frame(of: window), let screen = Self.screen(containing: frame) else { return }
        let target = Self.axVisibleFrame(of: screen)
        let key = Self.windowKey(window)
        switch Self.decision(frame: frame, target: target, saved: savedFrames[key]?.frame) {
        case let .fill(previous):
            savedFrames[key] = SavedWindow(element: window, frame: previous)
            Self.setFrame(target, of: window)
        case let .restore(previous):
            if Self.setFrame(previous, of: window) {
                savedFrames[key] = nil
            }
        }
    }

    // MARK: Geometry (AX uses top-left origin, AppKit uses bottom-left)

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = AX.attribute(window, kAXPositionAttribute),
              let sizeValue: AXValue = AX.attribute(window, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    static func setFrame(_ frame: CGRect, of window: AXUIElement) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        // Some apps clamp the first resize against the old position; apply position again.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return moved && resized
    }

    private static func screen(containing axFrame: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: axFrame.midX, y: primaryHeight - axFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    static func axVisibleFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return convertToAX(screen.visibleFrame, primaryHeight: primaryHeight)
    }

    static func convertToAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func windowKey(_ window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        // Equal AX elements hash equally, so this stays stable across lookups while the
        // title is free to change.
        return "\(pid)|\(CFHash(window))"
    }
}

private func greenButtonCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Event taps on the main run loop are called on the main thread.
    let location = event.location
    let optionDown = event.flags.contains(.maskAlternate)
    let swallow = MainActor.assumeIsolated {
        GreenButtonFill.current?.handle(type, location: location, optionDown: optionDown) ?? false
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
