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
    case wifiOffWhenWired
    case unmountSharesBeforeSleep
    case autoConnectShares
    case bluetoothOffWhileAsleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capsLockNoDelay: "Caps Lock with no delay"
        case .wakeVolumeLimit: "Cap volume at 40% after waking"
        case .muteIcon: "Show a menu bar icon only when muted"
        case .lowercaseExtensions: "Lowercase file extensions in Downloads"
        case .calendarInvites: "Open downloaded calendar invites in Fantastical"
        case .dmgInstaller: "Install apps from downloaded disk images"
        case .blockMusicLaunch: "Stop the play key from opening Music"
        case .clearNotificationsHotKey: "⌃⌥⌘N clears all notifications"
        case .dismissShortcutNotifications: "Dismiss \u{201C}Shortcut is running\u{201D} notifications"
        case .greenButtonFills: "Green window button fills the screen"
        case .ejectBeforeSleep: "Eject external drives before sleep"
        case .awakeWhileRendering: "Stay awake while rendering"
        case .cleanCopiedLinks: "Clean copied links"
        case .unzipDownloads: "Unzip downloaded .zip files"
        case .quitOnLastWindow: "Quit apps when their last window closes"
        case .wifiOffWhenWired: "Wi-Fi off while on Ethernet"
        case .unmountSharesBeforeSleep: "Disconnect network shares before sleep"
        case .autoConnectShares: "Keep work shares connected"
        case .bluetoothOffWhileAsleep: "Bluetooth off while asleep on battery"
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
        case .clearNotificationsHotKey: "Closes every notification on screen and in Notification Center."
        case .dismissShortcutNotifications: "Closes the banner Shortcuts shows while a shortcut runs."
        case .greenButtonFills: "Click the green button to fill the screen without full-screen mode; click again to restore. Hold ⌥ for normal full screen."
        case .ejectBeforeSleep: "No more \u{201C}Disk Not Ejected Properly\u{201D} after closing the lid. You're told after waking if a drive refused."
        case .awakeWhileRendering: "Keeps the Mac awake while After Effects, aerender, Media Encoder or Premiere is busy (half a core or more), until two minutes after it stops. The display can still sleep."
        case .cleanCopiedLinks: "Removes tracking (utm_, fbclid, YouTube si=…) from links as you copy them."
        case .unzipDownloads: "Extracts new .zip downloads next to the archive, then moves the zip to the Trash."
        case .quitOnLastWindow: "For the apps listed below."
        case .wifiOffWhenWired: "When a wired connection is live, Wi-Fi turns off; it comes back when you unplug. Off by default: AirDrop, Universal Control and Watch unlock need Wi-Fi on. Putting Ethernet above Wi-Fi in Network settings is usually the better fix."
        case .unmountSharesBeforeSleep: "Unmounts NAS shares as the Mac sleeps so waking on another network doesn't stall, then reconnects them once the server is reachable."
        case .autoConnectShares: "Mounts the shares listed below whenever their server is reachable (office network or VPN), using the password saved in your keychain."
        case .bluetoothOffWhileAsleep: "Saves a little battery in your bag; AirPods and Watch unlock take a few seconds longer after wake. Skipped on power."
        }
    }

    /// Available but off unless you turn them on: Wi-Fi off breaks AirDrop, Universal
    /// Control and Watch unlock, and Bluetooth off saves little on Apple silicon.
    static let offByDefault: Set<Tweak> = [.wifiOffWhenWired, .bluetoothOffWhileAsleep]

    /// Tweaks that need Accessibility permission to read or click other apps' windows.
    var needsAccessibility: Bool {
        switch self {
        case .clearNotificationsHotKey, .dismissShortcutNotifications, .greenButtonFills, .blockMusicLaunch, .quitOnLastWindow: true
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var enabled: Set<Tweak> = []
        for tweak in Tweak.allCases where defaults.object(forKey: tweak.rawValue) as? Bool ?? !Tweak.offByDefault.contains(tweak) {
            enabled.insert(tweak)
        }
        self.enabled = enabled
        quitApps = defaults.stringArray(forKey: "quitOnLastWindowApps") ?? Self.defaultQuitApps
        if let saved = defaults.stringArray(forKey: "autoConnectShares") {
            autoShares = saved
        } else {
            autoShares = NetworkShares.mounted().map(\.serverURL.absoluteString)
            defaults.set(autoShares, forKey: "autoConnectShares")
        }
    }

    func isOn(_ tweak: Tweak) -> Bool { enabled.contains(tweak) }

    /// Apps quit when their last window closes.
    private(set) var quitApps: [String] = []

    static let defaultQuitApps = ["com.apple.Preview", "com.apple.TextEdit"]

    /// Network shares kept connected; starts from whatever is mounted on first run.
    private(set) var autoShares: [String] = []

    func setAutoShares(_ urls: [String]) {
        autoShares = urls
        defaults.set(urls, forKey: "autoConnectShares")
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
