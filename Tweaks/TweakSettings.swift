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
        }
    }

    /// Tweaks that need Accessibility permission to read or click other apps' windows.
    var needsAccessibility: Bool {
        switch self {
        case .clearNotificationsHotKey, .dismissShortcutNotifications, .greenButtonFills, .blockMusicLaunch: true
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
        for tweak in Tweak.allCases where defaults.object(forKey: tweak.rawValue) as? Bool ?? true {
            enabled.insert(tweak)
        }
        self.enabled = enabled
    }

    func isOn(_ tweak: Tweak) -> Bool { enabled.contains(tweak) }

    func set(_ tweak: Tweak, on: Bool) {
        guard on != isOn(tweak) else { return }
        if on { enabled.insert(tweak) } else { enabled.remove(tweak) }
        defaults.set(on, forKey: tweak.rawValue)
        onChange?(tweak)
    }
}
