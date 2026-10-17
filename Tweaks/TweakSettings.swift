import Foundation
import Observation

/// Every tweak and whether it's on. Defaults match the Supercharge setup Tweaks replaced.
enum Tweak: String, CaseIterable, Identifiable, Sendable {
    case capsLockNoDelay
    case wakeVolumeLimit
    case muteIcon
    case lowercaseExtensions
    case calendarInvites
    case dmgInstaller
    case blockMusicLaunch
    case clearNotificationsHotKey
    case dismissShortcutNotifications
    case greenButtonFills
    case ejectBeforeSleep
    case awakeWhileRendering
    case cleanCopiedLinks
    case unzipDownloads
    case quitOnLastWindow
    case unmountSharesBeforeSleep
    case autoConnectShares
    case keepAwakeHotKey
    case windowLayouts
    case deviceVolumeLimits
    case safeEjectHotKey
    case duplicateDownloads

    var id: String { rawValue }

    var defaultEnabled: Bool {
        switch self {
        case .windowLayouts, .deviceVolumeLimits, .safeEjectHotKey, .duplicateDownloads: false
        default: true
        }
    }

    var title: String {
        switch self {
        case .capsLockNoDelay: "Caps Lock with no delay"
        case .wakeVolumeLimit: "Cap volume at 40% after waking"
        case .muteIcon: "Show a menu bar icon only when muted"
        case .lowercaseExtensions: "Lowercase file extensions in Downloads"
        case .calendarInvites: "Open downloaded calendar invites in Fantastical"
        case .dmgInstaller: "Install apps from downloaded disk images"
        case .blockMusicLaunch: "Stop the play key from opening Music"
        case .clearNotificationsHotKey: "Shortcut clears all notifications"
        case .dismissShortcutNotifications: "Dismiss \u{201C}Shortcut is running\u{201D} notifications"
        case .greenButtonFills: "Green window button fills the screen"
        case .ejectBeforeSleep: "Eject external drives before sleep"
        case .awakeWhileRendering: "Stay awake while rendering"
        case .cleanCopiedLinks: "Clean copied links"
        case .unzipDownloads: "Unzip downloaded .zip files"
        case .quitOnLastWindow: "Quit apps when their last window closes"
        case .unmountSharesBeforeSleep: "Disconnect network shares before sleep"
        case .autoConnectShares: "Keep work shares connected"
        case .keepAwakeHotKey: "Keep Awake shortcuts"
        case .windowLayouts: "Restore saved window layouts"
        case .deviceVolumeLimits: "Limit volume for each output device"
        case .safeEjectHotKey: "Safe-eject shortcut"
        case .duplicateDownloads: "Review duplicate downloads"
        }
    }

    var detail: String {
        switch self {
        case .capsLockNoDelay: "A normal tap toggles Caps Lock instantly instead of needing a short hold."
        case .wakeVolumeLimit: "So a loud setting from last night doesn't blast when you open the lid."
        case .muteIcon: "A speaker icon appears in the menu bar while sound is muted; click it to unmute."
        case .lowercaseExtensions: "Renames IMG_0001.JPG to IMG_0001.jpg as downloads land."
        case .calendarInvites: "Strips alarms, opens the invite in Fantastical, then moves the file to the Trash."
        case .dmgInstaller: "When a downloaded disk image with one app mounts, offers to copy it to Applications, eject and trash the image."
        case .blockMusicLaunch: "Quits Music when the play/pause key launches it. Opening Music yourself still works."
        case .clearNotificationsHotKey: "Closes every notification on screen. Set the keys under Shortcuts."
        case .dismissShortcutNotifications: "Closes the banner Shortcuts shows while a shortcut runs."
        case .greenButtonFills: "Click the green button to fill the screen without full-screen mode; click again to restore. Hold ⌥ for normal full screen."
        case .ejectBeforeSleep: "Tries to eject idle external drives before sleep. Busy drives stay connected; you are told after waking if a drive refused."
        case .awakeWhileRendering: "Keeps the Mac awake while After Effects, aerender, Media Encoder or Premiere is busy (half a core or more), until two minutes after it stops. The display can still sleep."
        case .cleanCopiedLinks: "Removes tracking (utm_, fbclid, YouTube si=…) from plain copied links within a few seconds. Wait briefly before pasting."
        case .unzipDownloads: "Extracts new .zip downloads next to the archive, then moves the zip to the Trash."
        case .quitOnLastWindow: "For the apps listed below."
        case .unmountSharesBeforeSleep: "Unmounts NAS shares as the Mac sleeps so waking on another network doesn't stall, then reconnects them once the server is reachable."
        case .keepAwakeHotKey: "Tap the Keep Awake shortcut for 12 hours (tap again to stop); hold it for the panel: durations, until a time, until a job or app finishes, or indefinitely. A cup shows in the menu bar while it's on. Stops itself at 15% battery."
        case .windowLayouts: "Save a layout for each monitor arrangement. Matching open windows return when that setup reconnects; closed and ambiguous windows stay untouched."
        case .deviceVolumeLimits: "Apply your chosen limits when changing output devices or raising the volume. Devices with hardware-only volume controls are left alone."
        case .safeEjectHotKey: "Set a shortcut to eject idle external drives. Drives in use stay connected, and the apps using them are listed below."
        case .duplicateDownloads: "Compare new downloads with existing files in Downloads. Duplicate copies are kept for review instead of being unzipped or imported. Empty files and links are skipped."
        case .autoConnectShares: "Mounts the shares listed below whenever their server is reachable (office network or VPN), using the password saved in your keychain."
        }
    }

    /// Tweaks that need Accessibility permission to read or click other apps' windows.
    var needsAccessibility: Bool {
        switch self {
        case .clearNotificationsHotKey, .dismissShortcutNotifications, .greenButtonFills, .blockMusicLaunch, .quitOnLastWindow, .windowLayouts: true
        default: false
        }
    }
}

@MainActor
@Observable
final class TweakSettings {
    private(set) var enabled: Set<Tweak>
    private let defaults: UserDefaults

    /// Called with the tweak whose switch changed.
    var onChange: ((Tweak) -> Void)?

    static let shareURLsKey = "autoConnectShareURLs"

    init(defaults: UserDefaults = .standard,
         mountedShares: () -> [String] = { NetworkShares.mounted().map(\.serverURL.absoluteString) }) {
        self.defaults = defaults
        // Older releases stored both the switch and the URLs under one key. An
        // array meant the default (enabled); a Boolean is explicit user intent.
        let legacyShares = defaults.stringArray(forKey: Tweak.autoConnectShares.rawValue)
        let shareURLs = defaults.stringArray(forKey: Self.shareURLsKey) ?? legacyShares ?? mountedShares()
        autoShares = shareURLs
        defaults.set(shareURLs, forKey: Self.shareURLsKey)
        if legacyShares != nil {
            defaults.set(true, forKey: Tweak.autoConnectShares.rawValue)
        }
        var enabled: Set<Tweak> = []
        for tweak in Tweak.allCases where defaults.object(forKey: tweak.rawValue) as? Bool ?? tweak.defaultEnabled {
            enabled.insert(tweak)
        }
        self.enabled = enabled
        quitApps = defaults.stringArray(forKey: "quitOnLastWindowApps") ?? Self.defaultQuitApps
    }

    func isOn(_ tweak: Tweak) -> Bool { enabled.contains(tweak) }

    /// Apps quit when their last window closes.
    private(set) var quitApps: [String] = []

    static let defaultQuitApps = ["com.apple.Preview", "com.apple.TextEdit"]

    /// Network shares kept connected; starts from whatever is mounted on first run.
    private(set) var autoShares: [String] = []

    func setAutoShares(_ urls: [String]) {
        autoShares = urls
        defaults.set(urls, forKey: Self.shareURLsKey)
        onChange?(.autoConnectShares)
    }

    func setQuitApps(_ bundleIDs: [String]) {
        quitApps = bundleIDs
        defaults.set(bundleIDs, forKey: "quitOnLastWindowApps")
        onChange?(.quitOnLastWindow)
    }

    func set(_ tweak: Tweak, on: Bool) {
        guard on != isOn(tweak) else { return }
        if on { enabled.insert(tweak) } else { enabled.remove(tweak) }
        defaults.set(on, forKey: tweak.rawValue)
        onChange?(tweak)
    }
}
