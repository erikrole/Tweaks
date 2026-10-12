import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct TweaksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Runs in the background with no menu bar icon. Opening Tweaks again (from Finder,
/// Spotlight or Raycast) shows its settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = TweakSettings()
    private let launchAtLogin = LaunchAtLoginController()
    private let controller = TweakController()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        installURLHandler()
        controller.settings = settings
        settings.onChange = { [weak self] tweak in self?.controller.apply(tweak) }
        controller.start()

        let firstLaunch = UserDefaults.standard.object(forKey: "hasLaunched") == nil
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch { showSettings() }
    }

    /// tweaks:// links. SwiftUI's app lifecycle installs its own URL handler during launch
    /// and doesn't pass URLs to the delegate when no scene claims them, so take the Apple
    /// Event over once launch has finished.
    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        controller.keepAwake.handle(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func showSettings() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Tweaks"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(settings: settings, controller: controller, launchAtLogin: launchAtLogin)
            )
            window.center()
            window.delegate = self
            self.window = window
        }
        controller.refreshAccessibility()
        // A normal app while the window is open: Dock icon, ⌘-Tab, its own menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the window keeps Tweaks running in the background and takes the Dock icon away.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// ⌘Q (or Quit from the Dock) while the window is open just closes it; Tweaks keeps
    /// working. The Quit Tweaks button in the window really quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.reallyQuit { return .terminateNow }
        if let window, window.isVisible {
            window.close()
            return .terminateCancel
        }
        return .terminateNow
    }

    /// Set by the window's Quit button and by relaunch, which really mean quit.
    static var reallyQuit = false
}

/// Starts and stops each tweak to match its switch.
@MainActor
@Observable
final class TweakController {
    var settings: TweakSettings?
    private(set) var hasAccessibility = AX.isTrusted
    private(set) var lastClearedCount: Int?

    private let mute = MuteIndicator()
    private let music = MusicLaunchBlocker()
    private let downloads = DownloadsWatcher()
    private let dmg = DMGInstaller()
    private let shortcutBanners = ShortcutBannerDismisser()
    private let greenButton = GreenButtonFill()
    private let ejector = SleepEjector()
    let renderAwake = RenderKeepAwake()
    private let linkCleaner = LinkCleaner()
    private let quitter = LastWindowQuitter()
    private let shareSleep = ShareSleepManager()
    private let shareConnect = ShareAutoConnect()

    let shortcuts = ShortcutStore()
    @ObservationIgnored private var hotKeys: [ShortcutAction: HotKey] = [:]
    @ObservationIgnored private var awakeTapOrHold: TapOrHold?
    let keepAwake = KeepAwake()
    private var capsLockTimer: Timer?
    private var accessibilityTimer: Timer?

    func start() {
        shortcuts.onChange = { [weak self] action in self?.register(action) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        Tweak.allCases.forEach(apply)
        // If any tweak needs Accessibility and it's missing, ask once at launch so the
        // system adds a fresh, correctly signed Tweaks entry to the list.
        if !AX.isTrusted, Tweak.allCases.contains(where: { $0.needsAccessibility && settings?.isOn($0) == true }) {
            AX.requestTrust()
        }
        refreshAccessibility()
        // Accessibility can be granted while Tweaks runs; pick it up without a relaunch.
        // macOS posts this when the Accessibility list changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self?.refreshAccessibility() }
            }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    func refreshAccessibility() {
        let trusted = AX.isTrusted
        UserDefaults.standard.set(trusted, forKey: "accessibilityTrusted")
        guard trusted != hasAccessibility else { return }
        hasAccessibility = trusted
        Tweak.allCases.filter(\.needsAccessibility).forEach(apply)
    }

    func apply(_ tweak: Tweak) {
        let on = settings?.isOn(tweak) ?? false
        switch tweak {
        case .capsLockNoDelay:
            capsLockTimer?.invalidate()
            capsLockTimer = nil
            guard on else { return }
            CapsLockTweak.apply()
            // Reapply now and then: plugging in a keyboard resets it.
            let timer = Timer(timeInterval: 300, repeats: true) { _ in CapsLockTweak.apply() }
            RunLoop.main.add(timer, forMode: .common)
            capsLockTimer = timer
        case .wakeVolumeLimit:
            break // Applied in didWake.
        case .muteIcon:
            on ? mute.start() : mute.stop()
        case .lowercaseExtensions, .calendarInvites, .unzipDownloads:
            downloads.lowercaseExtensions = settings?.isOn(.lowercaseExtensions) ?? false
            downloads.openCalendarInvites = settings?.isOn(.calendarInvites) ?? false
            downloads.unzipArchives = settings?.isOn(.unzipDownloads) ?? false
            let needed = downloads.lowercaseExtensions || downloads.openCalendarInvites || downloads.unzipArchives
            if needed, !downloads.isRunning { downloads.start() }
            if !needed { downloads.stop() }
        case .dmgInstaller:
            on ? dmg.start() : dmg.stop()
        case .blockMusicLaunch:
            on && hasAccessibility ? music.start() : music.stop()
        case .clearNotificationsHotKey:
            register(.clearNotifications)
        case .dismissShortcutNotifications:
            on && hasAccessibility ? shortcutBanners.start() : shortcutBanners.stop()
        case .greenButtonFills:
            greenButton.stop()
            if on && hasAccessibility { greenButton.start() }
        case .ejectBeforeSleep:
            if on { Notifier.requestPermission() }
            on ? ejector.start() : ejector.stop()
        case .awakeWhileRendering:
            on ? renderAwake.start() : renderAwake.stop()
        case .cleanCopiedLinks:
            on ? linkCleaner.start() : linkCleaner.stop()
        case .quitOnLastWindow:
            quitter.bundleIDs = Set(settings?.quitApps ?? [])
            on && hasAccessibility ? quitter.start() : quitter.stop()
        case .unmountSharesBeforeSleep:
            on ? shareSleep.start() : shareSleep.stop()
        case .keepAwakeHotKey:
            register(.keepAwake)
            register(.keepAwakePanel)
            register(.screenOff)
        case .autoConnectShares:
            shareConnect.shares = (settings?.autoShares ?? []).compactMap(URL.init(string:))
            shareConnect.stop()
            if on { shareConnect.start() }
        }
    }

    /// (Re)registers one action's global shortcut from the store, if its tweak is on.
    func register(_ action: ShortcutAction) {
        hotKeys[action]?.unregister()
        hotKeys[action] = nil
        let tweak: Tweak = action == .clearNotifications ? .clearNotificationsHotKey : .keepAwakeHotKey
        guard settings?.isOn(tweak) == true, let shortcut = shortcuts.shortcut(for: action) else { return }
        switch action {
        case .keepAwake:
            let tapOrHold = TapOrHold(
                onTap: { [weak self] in self?.keepAwake.toggleDefault() },
                onHold: { [weak self] in self?.keepAwake.showMenu() }
            )
            awakeTapOrHold = tapOrHold
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                                     onPress: { tapOrHold.pressed() }, onRelease: { tapOrHold.released() })
        case .keepAwakePanel:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.keepAwake.showMenu() }
        case .screenOff:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.keepAwake.sleepDisplayNow() }
        case .clearNotifications:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.clearNotifications() }
        }
    }

    func clearNotifications() {
        guard AX.isTrusted else {
            AX.requestTrust()
            return
        }
        lastClearedCount = NotificationCloser.closeAll()
    }

    private func didWake() {
        if settings?.isOn(.wakeVolumeLimit) == true {
            WakeVolume.apply()
        }
        if settings?.isOn(.capsLockNoDelay) == true { CapsLockTweak.apply() }
    }
}
