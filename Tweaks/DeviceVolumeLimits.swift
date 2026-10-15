import AppKit
import CoreAudio
import Observation

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    let device: AudioDeviceID
    let id: String
    let name: String
    let supportsVolume: Bool
}

struct DeviceVolumeRule: Codable, Equatable, Sendable {
    var name: String
    var maximum: Float
    var muteOnSwitchAway: Bool = false

    static func target(current: Float, maximum: Float) -> Float? {
        guard current.isFinite, maximum.isFinite else { return nil }
        let limit = min(1, max(0, maximum))
        return current > limit ? limit : nil
    }
}

/// Hardware can round a requested scalar upward. Bound correction attempts and
/// suppress repeated notifications for a device that cannot meet the ceiling.
struct VolumeLimitEnforcer {
    enum Result: Equatable { case applied(Float), rounded(Float), failed, unverified }
    private var lastVolume: Float?
    private var lastMaximum: Float?

    mutating func reset() { lastVolume = nil; lastMaximum = nil }

    mutating func enforce(current: Float, maximum: Float, write: (Float) -> Bool, read: () -> Float?) -> Result? {
        guard let limit = DeviceVolumeRule.target(current: current, maximum: maximum) else { reset(); return nil }
        guard current != lastVolume || limit != lastMaximum else { return nil }
        lastVolume = current
        lastMaximum = limit
        var request = limit
        var observed = current
        for _ in 0..<3 {
            guard write(request) else { return .failed }
            guard let actual = read(), actual.isFinite else { return .unverified }
            observed = actual
            lastVolume = actual
            if actual <= limit { reset(); return .applied(actual) }
            guard request > 0 else { break }
            request = max(0, request - max(0.005, actual - limit + 0.001))
        }
        return .rounded(observed)
    }
}

@MainActor
@Observable
final class DeviceVolumeLimits {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var rules: [String: DeviceVolumeRule]
    private(set) var status = "Set a limit for each output device you use."
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "Tweaks.audio-limits")
    private var active = false
    private var current: AudioOutputDevice?
    private var listenedDevice: AudioDeviceID?
    private var enforcer = VolumeLimitEnforcer()
    @ObservationIgnored private lazy var defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.deviceChanged() }
    }
    @ObservationIgnored private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.enforce() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = defaults.data(forKey: "deviceVolumeRules").flatMap { try? JSONDecoder().decode([String: DeviceVolumeRule].self, from: $0) } ?? [:]
    }

    func refreshDevices() { devices = AudioDeviceAccess.outputs() }

    func setRule(_ rule: DeviceVolumeRule?, for uid: String) {
        rules[uid] = rule.map { DeviceVolumeRule(name: $0.name, maximum: min(1, max(0, $0.maximum)), muteOnSwitchAway: $0.muteOnSwitchAway) }
        defaults.set(try? JSONEncoder().encode(rules), forKey: "deviceVolumeRules")
        enforcer.reset()
        enforce()
    }

    func start() {
        guard !active else { return }
        active = true
        var address = Self.defaultAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultListener)
        // Starting is not a device transition, so it must not mute a current output.
        current = nil
        deviceChanged()
    }

    func stop() {
        guard active else { return }
        active = false
        var address = Self.defaultAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultListener)
        detach()
        current = nil
    }

    private static var defaultAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func detach() {
        if let listenedDevice {
            var address = OutputAudio.volumeAddress()
            AudioObjectRemovePropertyListenerBlock(listenedDevice, &address, queue, volumeListener)
        }
        listenedDevice = nil
    }

    private func deviceChanged() {
        guard active else { return }
        let previous = current
        detach()
        refreshDevices()
        guard let id = OutputAudio.defaultDevice(), let next = AudioDeviceAccess.describe(id) else { status = "Waiting for an output device."; return }
        current = next
        enforcer.reset()
        if let previous, previous.id != next.id, rules[previous.id]?.muteOnSwitchAway == true {
            OutputAudio.setMuted(true, device: id)
        }
        if next.supportsVolume {
            var address = OutputAudio.volumeAddress()
            AudioObjectAddPropertyListenerBlock(id, &address, queue, volumeListener)
            listenedDevice = id
        }
        enforce()
    }

    private func enforce() {
        guard active, let current, OutputAudio.defaultDevice() == current.device,
              let rule = rules[current.id] else { return }
        guard current.supportsVolume, let volume = OutputAudio.volume(device: current.device) else {
            status = "\(current.name) uses its own hardware volume control."
            return
        }
        guard let result = enforcer.enforce(current: volume, maximum: rule.maximum,
                                            write: { OutputAudio.setVolume($0, device: current.device) },
                                            read: { OutputAudio.volume(device: current.device) }) else { return }
        switch result {
        case .applied(let value): status = "Set \(current.name) to \(Int(value * 100))%, within its limit."
        case .rounded(let value): status = "\(current.name) reported \(Int(value * 100))%, above its limit. Use its hardware control."
        case .failed: status = "macOS couldn't change \(current.name)'s volume. Use its hardware control."
        case .unverified: status = "Could not verify \(current.name)'s volume after setting its limit."
        }
    }
}

enum AudioDeviceAccess {
    static func outputs() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            return describe(id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func describe(_ device: AudioDeviceID) -> AudioOutputDevice? {
        guard let uid = string(device, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        var address = OutputAudio.volumeAddress()
        var settable = DarwinBoolean(false)
        let supported = AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        return AudioOutputDevice(device: device, id: uid, name: string(device, selector: kAudioObjectPropertyName) ?? uid, supportsVolume: supported)
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        return result == noErr ? value as String : nil
    }
}
