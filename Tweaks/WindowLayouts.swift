import AppKit
import ApplicationServices
import CryptoKit
import Observation

struct LayoutDisplay: Codable, Equatable, Sendable {
    let id: String
    let frame: CGRect
    let visible: CGRect

    static func key(_ displays: [LayoutDisplay]) -> String {
        displays.sorted { $0.id < $1.id }.map {
            "\($0.id):\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))"
        }.joined(separator: "|")
    }

    static func fit(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let width = min(max(1, frame.width), visible.width)
        let height = min(max(1, frame.height), visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }
}

struct SavedWindow: Codable, Equatable, Sendable {
    let app: String
    let identity: String
    let display: String
    let frame: CGRect

    static func identity(identifier: String?, document: String?, title: String?) -> String? {
        // Store fingerprints rather than document paths or window titles in preferences.
        guard let value = [document, identifier, title].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SavedLayout: Codable, Sendable {
    let key: String
    let displays: Int
    let windows: [SavedWindow]
}

struct LayoutApp: Sendable {
    let pid: pid_t
    let bundleID: String
}

final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

@MainActor
@Observable
final class WindowLayouts {
    private(set) var status = "Save the windows you want restored for this display setup."
    private(set) var busy = false
    private(set) var layouts: [SavedLayout]
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "Tweaks.window-layouts", qos: .utility)
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var operation: WorkCancellation?
    private var lastDisplayKey = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layouts = defaults.data(forKey: "savedWindowLayouts").flatMap { try? JSONDecoder().decode([SavedLayout].self, from: $0) } ?? []
    }

    func start() {
        guard observer == nil else { return }
        lastDisplayKey = LayoutDisplay.key(Self.displays())
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displayChanged() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending?.cancel()
        pending = nil
        operation?.cancel()
    }

    private func displayChanged() {
        guard observer != nil else { return }
        pending?.cancel()
        operation?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.observer != nil else { return }
            while self.busy && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, self.observer != nil else { return }
            let key = LayoutDisplay.key(Self.displays())
            guard key != self.lastDisplayKey else { return }
            self.lastDisplayKey = key
            await self.restore()
        }
    }

    func save() async {
        guard !busy, AX.isTrusted else { return }
        let displays = Self.displays()
        let apps = Self.apps()
        let token = WorkCancellation()
        operation = token
        busy = true
        defer { busy = false; operation = nil }
        let windows = (try? await FileWork.run(on: queue) { LayoutAccess.capture(apps: apps, displays: displays, token: token) }) ?? []
        guard !token.isCancelled, LayoutDisplay.key(Self.displays()) == LayoutDisplay.key(displays) else { return }
        guard !windows.isEmpty else { status = "No uniquely identifiable standard windows were available to save."; return }
        let layout = SavedLayout(key: LayoutDisplay.key(displays), displays: displays.count, windows: windows)
        layouts.removeAll { $0.key == layout.key }
        layouts.append(layout)
        persist()
        status = "Saved \(windows.count) windows for \(displays.count) display(s)."
    }

    func restore() async {
        guard !busy, AX.isTrusted else { return }
        let displays = Self.displays()
        guard let layout = layouts.first(where: { $0.key == LayoutDisplay.key(displays) }) else {
            status = "No saved layout for this display setup. Arrange your windows, then save it."
            return
        }
        let apps = Self.apps()
        let token = WorkCancellation()
        operation = token
        busy = true
        defer { busy = false; operation = nil }
        let count = (try? await FileWork.run(on: queue) { LayoutAccess.restore(layout, apps: apps, displays: displays, token: token) }) ?? 0
        if !token.isCancelled { status = "Restored \(count) of \(layout.windows.count) saved windows. Closed or ambiguous windows are left alone." }
    }

    func forgetCurrent() {
        operation?.cancel()
        layouts.removeAll { $0.key == LayoutDisplay.key(Self.displays()) }
        persist()
        status = "Forgot the saved layout for this display setup."
    }

    private func persist() { defaults.set(try? JSONEncoder().encode(layouts), forKey: "savedWindowLayouts") }

    static func displays() -> [LayoutDisplay] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let key = CFUUIDCreateString(nil, uuid) as String
            let visible = CGRect(x: screen.visibleFrame.minX, y: top - screen.visibleFrame.maxY,
                                 width: screen.visibleFrame.width, height: screen.visibleFrame.height)
            return LayoutDisplay(id: key, frame: CGDisplayBounds(id), visible: visible)
        }
    }

    private static func apps() -> [LayoutApp] {
        NSWorkspace.shared.runningApplications.compactMap {
            guard $0.activationPolicy == .regular, $0.processIdentifier != getpid(), let id = $0.bundleIdentifier else { return nil }
            return LayoutApp(pid: $0.processIdentifier, bundleID: id)
        }
    }
}

/// AX objects are created and used entirely on the layout queue.
private enum LayoutAccess {
    struct Window { let app: String; let id: String; let element: AXUIElement; let frame: CGRect }

    static func windows(apps: [LayoutApp], token: WorkCancellation) -> [Window] {
        var result: [Window] = []
        for app in apps {
            if token.isCancelled { break }
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            let windows: [AXUIElement] = AX.attribute(element, kAXWindowsAttribute) ?? []
            for window in windows.prefix(100) {
                if token.isCancelled || result.count >= 500 { return result }
                AXUIElementSetMessagingTimeout(window, 0.15)
                guard (AX.attribute(window, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
                      (AX.attribute(window, kAXMinimizedAttribute) as Bool?) != true,
                      (AX.attribute(window, "AXFullScreen") as Bool?) != true,
                      let id = SavedWindow.identity(identifier: AX.attribute(window, kAXIdentifierAttribute),
                                                    document: AX.attribute(window, kAXDocumentAttribute),
                                                    title: AX.attribute(window, kAXTitleAttribute)),
                      let position: AXValue = AX.attribute(window, kAXPositionAttribute),
                      let size: AXValue = AX.attribute(window, kAXSizeAttribute) else { continue }
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &dimensions),
                      dimensions.width > 0, dimensions.height > 0 else { continue }
                result.append(Window(app: app.bundleID, id: id, element: window, frame: CGRect(origin: origin, size: dimensions)))
            }
        }
        return result
    }

    static func capture(apps: [LayoutApp], displays: [LayoutDisplay], token: WorkCancellation) -> [SavedWindow] {
        let all = windows(apps: apps, token: token)
        return all.compactMap { window in
            guard all.filter({ $0.app == window.app && $0.id == window.id }).count == 1,
                  let display = displays.max(by: { area(window.frame.intersection($0.frame)) < area(window.frame.intersection($1.frame)) })
            else { return nil }
            return SavedWindow(app: window.app, identity: window.id, display: display.id, frame: window.frame)
        }
    }

    static func restore(_ layout: SavedLayout, apps: [LayoutApp], displays: [LayoutDisplay], token: WorkCancellation) -> Int {
        let all = windows(apps: apps, token: token)
        var restored = 0
        for saved in layout.windows {
            if token.isCancelled { break }
            let matches = all.filter { $0.app == saved.app && $0.id == saved.identity }
            guard matches.count == 1, let window = matches.first,
                  let display = displays.first(where: { $0.id == saved.display }) else { continue }
            var frame = LayoutDisplay.fit(saved.frame, in: display.visible)
            guard let size = AXValueCreate(.cgSize, &frame.size), let position = AXValueCreate(.cgPoint, &frame.origin) else { continue }
            let resized = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, size)
            if token.isCancelled { break }
            let moved = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, position)
            if resized == .success && moved == .success { restored += 1 }
        }
        return restored
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}
