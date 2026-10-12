import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Caps Lock

/// Removes the short hold macOS requires before Caps Lock turns on. The setting lives in
/// the HID system and resets when a keyboard reconnects or the Mac restarts, so it's
/// reapplied on launch, on wake and every few minutes.
enum CapsLockTweak {
    static func apply() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", #"{"CapsLockDelayOverride":0}"#]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// MARK: - Audio

/// Default output device volume and mute, via Core Audio.
enum OutputAudio {
    static func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func volume() -> Float? {
        guard let device = defaultDevice() else { return nil }
        var address = volumeAddress()
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ volume: Float) {
        guard let device = defaultDevice() else { return }
        var address = volumeAddress()
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted() -> Bool {
        guard let device = defaultDevice() else { return false }
        var address = muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultDevice() else { return }
        var address = muteAddress()
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// The volume to use after waking: unchanged if already at or under the cap.
enum WakeVolume {
    static let cap: Float = 0.4

    static func target(current: Float, cap: Float = cap) -> Float? {
        current > cap ? cap : nil
    }

    static func apply() {
        guard let current = OutputAudio.volume(), let target = target(current: current) else { return }
        OutputAudio.setVolume(target)
    }
}

/// Shows a speaker icon in the menu bar while the default output is muted. Listens for
/// mute and default-device changes instead of polling.
@MainActor
final class MuteIndicator {
    private var statusItem: NSStatusItem?
    private var listenedDevice: AudioDeviceID?
    private var isActive = false
    private let queue = DispatchQueue(label: "Tweaks.mute")

    private lazy var muteListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.refresh() }
    }

    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in
            self?.attachToDefaultDevice()
            self?.refresh()
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        attachToDefaultDevice()
        refresh()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        detach()
        hide()
    }

    private func attachToDefaultDevice() {
        detach()
        guard let device = OutputAudio.defaultDevice() else { return }
        var address = OutputAudio.muteAddress()
        AudioObjectAddPropertyListenerBlock(device, &address, queue, muteListener)
        listenedDevice = device
    }

    private func detach() {
        guard let device = listenedDevice else { return }
        var address = OutputAudio.muteAddress()
        AudioObjectRemovePropertyListenerBlock(device, &address, queue, muteListener)
        listenedDevice = nil
    }

    private func refresh() {
        guard isActive else { return }
        OutputAudio.isMuted() ? show() : hide()
    }

    private func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Sound muted")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Sound is muted. Click to unmute."
        item.button?.target = self
        item.button?.action = #selector(unmute)
        statusItem = item
    }

    private func hide() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func unmute() {
        OutputAudio.setMuted(false)
        refresh()
    }
}

// MARK: - Music

/// Quits Music when it launches within a moment of the play/pause key, which is how
/// macOS's media-key handling opens it. Opening Music any other way is left alone.
@MainActor
final class MusicLaunchBlocker {
    private var keyMonitor: Any?
    private var launchObserver: NSObjectProtocol?
    private var lastPlayKey: Date?

    static let musicBundleID = "com.apple.Music"
    /// How soon after the key a launch counts as caused by it.
    static let window: TimeInterval = 3

    static func shouldBlock(launchAt: Date, lastPlayKey: Date?) -> Bool {
        guard let lastPlayKey else { return false }
        let gap = launchAt.timeIntervalSince(lastPlayKey)
        return gap >= 0 && gap <= window
    }

    func start() {
        guard keyMonitor == nil else { return }
        // Media keys arrive as system-defined events; subtype 8 carries the key code.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let keyCode = (event.data1 & 0xFFFF_0000) >> 16
            let keyDown = ((event.data1 & 0xFF00) >> 8) == 0xA
            guard keyDown, keyCode == Int(NX_KEYTYPE_PLAY) else { return }
            Task { @MainActor in self?.lastPlayKey = Date() }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.musicBundleID else { return }
            Task { @MainActor in
                guard let self, Self.shouldBlock(launchAt: Date(), lastPlayKey: self.lastPlayKey) else { return }
                app.terminate()
            }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
    }
}
