import AppKit
import Carbon.HIToolbox
import FinderUtilitiesKit

@main
enum TweaksMain {
    static func main() {
        // The main thread is the main actor; NSApplication.delegate is weak.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

/// Runs in the background with no menu bar icon. Opening Tweaks again (from Finder,
/// Spotlight or Raycast) shows its settings window. AppKit only: SwiftUI stays unmapped
/// while Tweaks is idle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // The XCTest host returns before touching any user preference model, including
    // migrations performed by initializers.
    private lazy var settings = TweakSettings()
    private lazy var launchAtLogin = LaunchAtLoginController()
    private lazy var controller = TweakController()
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard InstanceGuard.mayRun else {
            NSApp.terminate(nil)
            return
        }
        installURLHandler()
        controller.settings = settings
        settings.onChange = { [weak self] tweak in
            self?.controller.apply(tweak)
            self?.settingsWindow?.sync()
        }
        controller.start()

        let firstLaunch = UserDefaults.standard.object(forKey: "hasLaunched") == nil
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch { showSettings() }
    }

    /// tweaks:// links, taken directly because there is no SwiftUI scene to claim them.
    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        if let files = ImageActionRequest.files(from: url) {
            controller.imageActions.show(files)
            return
        }
        controller.keepAwake.handle(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = SettingsWindowController(settings: settings, tweaks: controller, launchAtLogin: launchAtLogin)
            window.onClose = { [weak self] in
                self?.settingsWindow = nil
                NSApp.setActivationPolicy(.accessory)
            }
            settingsWindow = window
        }
        controller.refreshAccessibility()
        settingsWindow?.sync()
        // A normal app while the window is open: Dock icon, ⌘-Tab, its own menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.showWindow(nil)
    }

    /// ⌘Q (or Quit from the Dock) while the window is open just closes it; Tweaks keeps
    /// working. The Quit Tweaks button in the window really quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !Self.reallyQuit, let window = settingsWindow?.window, window.isVisible {
            window.close()
            return .terminateCancel
        }
        // Logout, restart and shutdown must never be held up: Wi-Fi restore is attempted once
        // and the saved state finishes the job at the next launch.
        let systemQuit = Self.isSystemQuit()
        var replied = false
        let reply: @MainActor (Bool) -> Void = { restored in
            guard !replied else { return }
            replied = true
            if !restored && !systemQuit {
                Self.reallyQuit = false
                self.controller.apply(.preferEthernetForVPN)
                HUD.show("Restoring Wi-Fi; Tweaks will keep running", symbol: "wifi.exclamationmark", duration: 4)
            }
            sender.reply(toApplicationShouldTerminate: restored || systemQuit)
        }
        controller.ethernetHandoff.prepareForTermination { restored in reply(restored) }
        // A handoff in progress can keep the network queue busy; don't wait on it forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitDeadline) {
            MainActor.assumeIsolated { reply(false) }
        }
        return .terminateLater
    }

    static let quitDeadline: TimeInterval = 8

    /// True when macOS is logging out, restarting or shutting down.
    static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(reason)
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
    private let shareSleep: ShareSleepManager
    private let shareConnect = ShareAutoConnect()
    let ethernetHandoff = EthernetVPNHandoff()

    let windowLayouts: WindowLayouts
    let volumeLimits: DeviceVolumeLimits
    let safeEject = SafeEject()
    let imageActions = ImageActions()
    let duplicates = DuplicateReview()

    let shortcuts: ShortcutStore
    @ObservationIgnored private var hotKeys: [ShortcutAction: HotKey] = [:]
    private(set) var shortcutErrors: [ShortcutAction: String] = [:]
    @ObservationIgnored private var awakeTapOrHold: TapOrHold?
    let keepAwake = KeepAwake()
    private var capsLockTimer: Timer?
    private var accessibilityTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        shareSleep = ShareSleepManager(defaults: defaults)
        windowLayouts = WindowLayouts(defaults: defaults)
        volumeLimits = DeviceVolumeLimits(defaults: defaults)
        shortcuts = ShortcutStore(defaults: defaults)
    }

    func start() {
        shareSleep.recoverPending()
        ethernetHandoff.recoverPending()
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
        // macOS posts this when the Accessibility list changes. The timer is only a backup
        // while permission is still missing, so a trusted idle process doesn't wake for it.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self?.refreshAccessibility() }
            }
        }
    }

    /// Backup poll, only while Accessibility is still off.
    static let accessibilityInterval: TimeInterval = 30

    func refreshAccessibility() {
        let trusted = AX.isTrusted
        UserDefaults.standard.set(trusted, forKey: "accessibilityTrusted")
        if trusted != hasAccessibility {
            hasAccessibility = trusted
            Tweak.allCases.filter(\.needsAccessibility).forEach(apply)
        }
        armAccessibilityTimer()
    }

    private func armAccessibilityTimer() {
        if hasAccessibility {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            return
        }
        guard accessibilityTimer == nil else { return }
        let timer = Timer(timeInterval: Self.accessibilityInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibility() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    func apply(_ tweak: Tweak) {
        let on = settings?.isOn(tweak) ?? false
        switch tweak {
        case .capsLockNoDelay:
            capsLockTimer?.invalidate()
            capsLockTimer = nil
            if on {
                CapsLockTweak.apply()
                // Reapply now and then: plugging in a keyboard resets it.
                let timer = Timer(timeInterval: CapsLockTweak.reapplyInterval, repeats: true) { _ in CapsLockTweak.apply() }
                timer.tolerance = 60
                RunLoop.main.add(timer, forMode: .common)
                capsLockTimer = timer
            } else {
                CapsLockTweak.restore()
            }
        case .wakeVolumeLimit:
            break // Applied in didWake.
        case .muteIcon:
            on ? mute.start() : mute.stop()
        case .lowercaseExtensions, .calendarInvites, .unzipDownloads, .duplicateDownloads:
            downloads.lowercaseExtensions = settings?.isOn(.lowercaseExtensions) ?? false
            downloads.openCalendarInvites = settings?.isOn(.calendarInvites) ?? false
            downloads.unzipArchives = settings?.isOn(.unzipDownloads) ?? false
            downloads.onDuplicate = { [weak self] match in self?.duplicates.add(match) }
            downloads.detectDuplicates = settings?.isOn(.duplicateDownloads) ?? false
            if tweak == .duplicateDownloads {
                if on { Notifier.requestPermission() } else { duplicates.clear() }
            }
            let needed = downloads.lowercaseExtensions || downloads.openCalendarInvites || downloads.unzipArchives || downloads.detectDuplicates
            if needed, !downloads.isRunning { downloads.start() }
            if !needed { downloads.stop() }
        case .dmgInstaller:
            on ? dmg.start() : dmg.stop()
        case .windowLayouts:
            on && hasAccessibility ? windowLayouts.start() : windowLayouts.stop()
            register(.saveWindowLayout)
            register(.restoreWindowLayout)
        case .deviceVolumeLimits:
            on ? volumeLimits.start() : volumeLimits.stop()
        case .safeEjectHotKey:
            if on { Notifier.requestPermission() }
            register(.safeEject)
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
            if on && hasAccessibility {
                quitter.start()
                quitter.appsChanged()
            } else {
                quitter.stop()
            }
        case .preferEthernetForVPN:
            on ? ethernetHandoff.start() : ethernetHandoff.stop()
        case .unmountSharesBeforeSleep:
            on ? shareSleep.start() : shareSleep.stop()
        case .keepAwakeHotKey:
            register(.keepAwake)
            register(.keepAwakePanel)
            register(.screenOff)
            if !on { keepAwake.stop() }
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
        shortcutErrors[action] = nil
        let tweak: Tweak
        switch action {
        case .clearNotifications: tweak = .clearNotificationsHotKey
        case .saveWindowLayout, .restoreWindowLayout: tweak = .windowLayouts
        case .safeEject: tweak = .safeEjectHotKey
        default: tweak = .keepAwakeHotKey
        }
        guard settings?.isOn(tweak) == true, let shortcut = shortcuts.shortcut(for: action) else { return }
        switch action {
        case .keepAwake:
            let tapOrHold = TapOrHold(
                onTap: { [weak self] in self?.keepAwake.toggleDefault() },
                onHold: { [weak self] in self?.keepAwake.holdDefault() }
            )
            awakeTapOrHold = tapOrHold
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                                     onPress: { tapOrHold.pressed() }, onRelease: { tapOrHold.released() })
        case .keepAwakePanel:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.keepAwake.showMenu() }
        case .screenOff:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.keepAwake.sleepDisplayNow() }
        case .saveWindowLayout:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                Task { await self?.windowLayouts.save() }
            }
        case .restoreWindowLayout:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                Task { await self?.windowLayouts.restore() }
            }
        case .safeEject:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                Task { await self?.safeEject.ejectIdleDrives(notify: true) }
            }
        case .clearNotifications:
            hotKeys[action] = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.clearNotifications() }
        }
        if let hotKey = hotKeys[action] {
            shortcutErrors[action] = HotKey.failureMessage(status: hotKey.registrationStatus)
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


/// Keeps a second copy from watching the same folders or claiming login-item and
/// privacy grants under a different signature (a build-folder copy next to the installed app).
enum InstanceGuard {
    static var mayRun: Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let id = Bundle.main.bundleIdentifier ?? "com.erole.Tweaks"
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            return false
        }
        let installed = URL(filePath: "/Applications/Tweaks.app").resolvingSymlinksInPath()
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if current.path != installed.path, FileManager.default.fileExists(atPath: installed.path) { return false }
        return true
    }
}
