import AppKit
import CoreAudio
import Foundation

// MARK: - Caps Lock

/// Removes the short hold macOS requires before Caps Lock turns on. The setting lives in
/// the HID system and resets when a keyboard reconnects or the Mac restarts, so it's
/// reapplied on launch, on wake and every few minutes.
/// Caps Lock delay, in nanoseconds, as `hidutil` stores `CapsLockDelayOverride`.
enum CapsLockDelay {
    static let disabled = 0
    /// macOS's usual hold before Caps Lock toggles. Used when the tweak is turned off
    /// and Tweaks never saw a different value (the property was already 0, or unset).
    static let systemDefaultNanoseconds = 250_000_000
    static let savedKey = "capsLockDelayOverrideOriginal"

    static func parse(hidutilOutput: String) -> Int? {
        let trimmed = hidutilOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(null)" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let value = json["CapsLockDelayOverride"]
        if value is NSNull { return nil }
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// A delay worth putting back. The tweak's own 0 is not an original setting.
    static func original(from current: Int?) -> Int? {
        guard let current, current > 0 else { return nil }
        return current
    }

    static func restoreNanoseconds(saved: Int?) -> Int {
        if let saved, saved > 0 { return saved }
        return systemDefaultNanoseconds
    }
}

enum CapsLockTweak {
    /// How often to put the override back. Keyboards forget it on reconnect; wake covers the common case.
    static let reapplyInterval: TimeInterval = 15 * 60

    static func apply(defaults: UserDefaults = .standard, reader: () -> Int? = readCurrent, writer: (Int) -> Void = write) {
        if defaults.object(forKey: CapsLockDelay.savedKey) == nil,
           let original = CapsLockDelay.original(from: reader()) {
            defaults.set(original, forKey: CapsLockDelay.savedKey)
        }
        writer(CapsLockDelay.disabled)
    }

    static func restore(defaults: UserDefaults = .standard, writer: (Int) -> Void = write) {
        let saved = defaults.object(forKey: CapsLockDelay.savedKey) as? Int
        writer(CapsLockDelay.restoreNanoseconds(saved: saved))
    }

    private static func readCurrent() -> Int? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hidutil")
        process.arguments = ["property", "--get", "CapsLockDelayOverride"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CapsLockDelay.parse(hidutilOutput: String(decoding: data, as: UTF8.self))
    }

    private static func write(_ nanoseconds: Int) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", "{\"CapsLockDelayOverride\":\(nanoseconds)}"]
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

    /// Per-channel scalar. The macOS 27 SDK no longer has
    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`; the main element is the
    /// device volume, and channels 1 and 2 cover devices that only expose a pair.
    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func readScalar(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = volumeAddress(element: element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeScalar(_ device: AudioDeviceID, element: AudioObjectPropertyElement, _ volume: Float32) -> Bool {
        var address = volumeAddress(element: element)
        var value = volume
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
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
        if let value = readScalar(device, element: kAudioObjectPropertyElementMain) { return value }
        return readScalar(device, element: 1)
    }

    static func setVolume(_ volume: Float) {
        guard let device = defaultDevice() else { return }
        let value = Float32(min(max(volume, 0), 1))
        if writeScalar(device, element: kAudioObjectPropertyElementMain, value) { return }
        _ = writeScalar(device, element: 1, value)
        _ = writeScalar(device, element: 2, value)
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
            let pid = app.processIdentifier
            Task { @MainActor in
                guard let self, Self.shouldBlock(launchAt: Date(), lastPlayKey: self.lastPlayKey) else { return }
                NSRunningApplication(processIdentifier: pid)?.terminate()
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
