import AppKit
import CoreAudio
import Foundation
import IOKit.hidsystem

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
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = json["CapsLockDelayOverride"] as? Int, value >= 0 { return value }
        let values = Set(table(hidutilOutput: trimmed).values)
        // A single scalar must never flatten different device settings.
        return values.count == 1 ? values.first : nil
    }

    static func table(hidutilOutput: String) -> [String: Int] {
        var values: [String: Int] = [:]
        for line in hidutilOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, UInt64(fields[0], radix: 16) != nil,
                  fields[1] == "CapsLockDelayOverride", let value = Int(fields[2]), value >= 0 else { continue }
            values[String(fields[0])] = value
        }
        return values
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

    // Native HID services let us restore each device independently. Registry IDs
    // are scoped to a boot session, so a reused ID never inherits another device's value.
    static let deviceOriginalsKey = "capsLockDeviceOriginals"
    static let bootKey = "capsLockOriginalsBoot"

    static func apply(defaults: UserDefaults = .standard) {
        withServices { services in
            let current = Dictionary(uniqueKeysWithValues: services.map { service in
                (registryID(service), (IOHIDServiceClientCopyProperty(service, "CapsLockDelayOverride" as CFString) as? NSNumber)?.intValue)
            })
            apply(current: current, boot: bootSession(), defaults: defaults) { id, value in
                guard let service = services.first(where: { registryID($0) == id }) else { return false }
                return IOHIDServiceClientSetProperty(service, "CapsLockDelayOverride" as CFString, NSNumber(value: value))
            }
        }
    }

    static func restore(defaults: UserDefaults = .standard) {
        withServices { services in
            restore(ids: services.map(registryID), boot: bootSession(), defaults: defaults) { id, value in
                guard let service = services.first(where: { registryID($0) == id }) else { return false }
                return IOHIDServiceClientSetProperty(service, "CapsLockDelayOverride" as CFString, NSNumber(value: value))
            }
        }
    }

    static func apply(current: [String: Int?], boot: String, defaults: UserDefaults,
                      write: (String, Int) -> Bool) {
        saveOriginals(current, boot: boot, defaults: defaults)
        for id in current.keys { _ = write(id, CapsLockDelay.disabled) }
    }

    static func restore(ids: [String], boot: String, defaults: UserDefaults,
                        write: (String, Int) -> Bool) {
        var saved = originals(boot: boot, defaults: defaults)
        for id in ids {
            guard let value = saved[id] else { continue }
            if write(id, value) { saved[id] = nil }
        }
        // A later enable captures the then-current setting; failed/disconnected
        // devices keep their original until a successful restore.
        defaults.set(saved, forKey: deviceOriginalsKey)
    }

    static func saveOriginals(_ current: [String: Int?], boot: String, defaults: UserDefaults) {
        var saved = originals(boot: boot, defaults: defaults)
        for (id, value) in current where saved[id] == nil {
            let legacy = defaults.object(forKey: CapsLockDelay.savedKey) as? Int
            saved[id] = CapsLockDelay.original(from: value) ?? CapsLockDelay.restoreNanoseconds(saved: legacy)
        }
        defaults.set(saved, forKey: deviceOriginalsKey)
        defaults.set(boot, forKey: bootKey)
    }

    static func originals(boot: String, defaults: UserDefaults) -> [String: Int] {
        guard boot != "unknown", defaults.string(forKey: bootKey) == boot else { return [:] }
        return defaults.dictionary(forKey: deviceOriginalsKey) as? [String: Int] ?? [:]
    }

    private static func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    private static func registryID(_ service: IOHIDServiceClient) -> String {
        String((IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0, radix: 16)
    }

    private static func withServices(_ body: ([IOHIDServiceClient]) -> Void) {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        body(services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 })
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

    /// Master or individual output-channel scalar.
    static func volumeAddress(element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
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

    static func volume(device: AudioDeviceID? = nil) -> Float? {
        volumes(device: device)?.values.max()
    }

    static func volumes(device: AudioDeviceID? = nil) -> [UInt32: Float]? {
        guard let device = device ?? defaultDevice() else { return nil }
        return AudioVolumeChannels.snapshot(elements: volumeElements(device), read: { readScalar(device, element: $0) })
    }

    static func volumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        AudioVolumeChannels.elements(channelCount: outputChannelCount(device)) { element in
            var address = volumeAddress(element: element)
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(device, &address)
                && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }
    }

    private static func outputChannelCount(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + $1.mNumberChannels }
    }

    /// Clamp every writable element without raising a quieter channel.
    static func capVolume(_ maximum: Float, device: AudioDeviceID? = nil) -> Bool {
        guard let device = device ?? defaultDevice() else { return false }
        return AudioVolumeChannels.cap(maximum, elements: volumeElements(device),
                                       read: { readScalar(device, element: $0) },
                                       write: { writeScalar(device, element: $0, $1) })
    }

    @discardableResult
    static func setVolume(_ volume: Float, device: AudioDeviceID? = nil) -> Bool {
        guard let device = device ?? defaultDevice(), volume.isFinite else { return false }
        let value = Float32(min(max(volume, 0), 1))
        let elements = volumeElements(device)
        let results = elements.map { writeScalar(device, element: $0, value) }
        return !results.isEmpty && results.allSatisfy { $0 }
    }

    static func isMuted() -> Bool {
        guard let device = defaultDevice() else { return false }
        var address = muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func setMuted(_ muted: Bool, device: AudioDeviceID? = nil) {
        guard let device = device ?? defaultDevice() else { return }
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
        _ = OutputAudio.capVolume(target)
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

    nonisolated static let musicBundleID = "com.apple.Music"
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
