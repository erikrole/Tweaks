import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Accessibility helpers

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

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
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// ⌃⌥⌘N by default.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_N), modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey), action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.actions[id]?() }
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5457_4B53), id: id) // "TWKS"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        Self.actions[id] = nil
    }
}

/// Watches for the "Shortcut is running" banner and closes it as soon as it appears.
@MainActor
final class ShortcutBannerDismisser {
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        // A light poll: the Notification Center tree is small and this costs well under a
        // millisecond when nothing is showing.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AX.isTrusted else { return }
                for notification in NotificationCloser.visibleNotifications()
                where NotificationCloser.isShortcutRunning(notification.summary) {
                    if let action = notification.closeAction {
                        AXUIElementPerformAction(notification.element, action as CFString)
                    }
                }
            }
        }
        timer.tolerance = 0.3
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
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var savedFrames: [String: CGRect] = [:]
    private var swallowNextMouseUp = false
    fileprivate static weak var current: GreenButtonFill?

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
        guard !optionDown else { return false }
        // Every click on the Mac passes through here, so rule most out without asking
        // any app anything: the green button sits in a window's top-left corner.
        guard Self.isNearWindowCorner(location) else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        // A busy app (After Effects mid-render) answers slowly; don't hold the click.
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &hit) == .success,
              let button = hit,
              (AX.attribute(button, kAXSubroleAttribute) as String?) == (kAXFullScreenButtonSubrole as String),
              let window: AXUIElement = AX.attribute(button, kAXWindowAttribute)
        else { return false }

        toggleFill(window)
        swallowNextMouseUp = true
        return true
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
        if Self.approximatelyEqual(frame, target), let saved = savedFrames[key] {
            Self.setFrame(saved, of: window)
            savedFrames[key] = nil
        } else {
            savedFrames[key] = frame
            Self.setFrame(target, of: window)
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

    private static func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var position = frame.origin
        var size = frame.size
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        // Some apps clamp the first resize against the old position; apply position again.
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
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
