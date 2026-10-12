import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = TweakSettings()
    private let launchAtLogin = LaunchAtLoginController()
    private let controller = TweakController()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        controller.settings = settings
        settings.onChange = { [weak self] tweak in self?.controller.apply(tweak) }
        controller.start()

        let firstLaunch = UserDefaults.standard.object(forKey: "hasLaunched") == nil
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch { showSettings() }
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
            self.window = window
        }
        controller.refreshAccessibility()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
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
    private var hotKey: HotKey?
    private var capsLockTimer: Timer?
    private var accessibilityTimer: Timer?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        Tweak.allCases.forEach(apply)
        // Accessibility can be granted while Tweaks runs; pick it up without a relaunch.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    func refreshAccessibility() {
        let trusted = AX.isTrusted
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
            hotKey?.unregister()
            hotKey = nil
            if on {
                hotKey = HotKey { [weak self] in self?.clearNotifications() }
            }
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
            // Some outputs restore their own level a moment after wake; check again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { WakeVolume.apply() }
        }
        if settings?.isOn(.capsLockNoDelay) == true { CapsLockTweak.apply() }
    }
}
