import AppKit
import CoreAudio
import Observation

/// Shared by discovery, listeners and writes, including devices with no master scalar.
enum AudioVolumeChannels {
    static func elements(channelCount: UInt32, writable: (UInt32) -> Bool) -> [UInt32] {
        if writable(0) { return [0] }
        guard channelCount > 0 else { return [] }
        return (1...channelCount).filter(writable)
    }

    static func maximum(elements: [UInt32], read: (UInt32) -> Float?) -> Float? {
        snapshot(elements: elements, read: read)?.values.max()
    }

    static func snapshot(elements: [UInt32], read: (UInt32) -> Float?) -> [UInt32: Float]? {
        var values: [UInt32: Float] = [:]
        for element in elements {
            guard let value = read(element), value.isFinite else { return nil }
            values[element] = value
        }
        return values.isEmpty ? nil : values
    }

    static func cap(_ limit: Float, elements: [UInt32], read: (UInt32) -> Float?, write: (UInt32, Float) -> Bool) -> Bool {
        guard limit.isFinite, !elements.isEmpty else { return false }
        var success = true
        for element in elements {
            guard let value = read(element), value.isFinite else { success = false; continue }
            if let target = DeviceVolumeRule.target(current: value, maximum: limit), !write(element, target) { success = false }
        }
        return success
    }
}

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

/// Suppression must compare every channel: a second channel can rise above the
/// cap without changing the maximum of a hardware-rounded first channel.
struct ChannelVolumeLimitEnforcer {
    private(set) var verifiedWithinLimit = false
    private var scalar = VolumeLimitEnforcer()
    private var lastReadback: [UInt32: Float]?

    mutating func reset() { scalar.reset(); lastReadback = nil; verifiedWithinLimit = false }

    mutating func enforce(maximum: Float, read: () -> [UInt32: Float]?, write: (Float) -> Bool) -> VolumeLimitEnforcer.Result? {
        verifiedWithinLimit = false
        guard let values = read(), let current = values.values.max() else { return .unverified }
        verifiedWithinLimit = values.values.allSatisfy { $0.isFinite && $0 <= min(1, max(0, maximum)) }
        if values != lastReadback { scalar.reset() }
        var evaluated: [UInt32: Float]? = values
        defer { lastReadback = evaluated }
        return scalar.enforce(current: current, maximum: maximum, write: write, read: {
            evaluated = read()
            return evaluated?.values.max()
        })
    }
}

@MainActor
@Observable
final class DeviceVolumeLimits {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var rules: [String: DeviceVolumeRule]
    private(set) var wakeStatus: FeatureRuntime?
    private(set) var statusPhase = FeatureRuntime.Phase.ready
    private(set) var status = "Set a limit for each output device you use."
    private(set) var wakeMaximum: Float
    var onAction: ((String) -> Void)?
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "Tweaks.audio-limits")
    private var active = false
    private var current: AudioOutputDevice?
    private var listenedDevice: AudioDeviceID?
    private var listenedElements: [UInt32] = []
    private var enforcer = ChannelVolumeLimitEnforcer()
    @ObservationIgnored private lazy var defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.deviceChanged() }
    }
    @ObservationIgnored private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.enforce() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: "audioWakeMaximum") as? Float ?? WakeVolume.cap
        wakeMaximum = saved.isFinite ? min(1, max(0, saved)) : WakeVolume.cap
        rules = defaults.data(forKey: "deviceVolumeRules").flatMap { try? JSONDecoder().decode([String: DeviceVolumeRule].self, from: $0) } ?? [:]
    }

    func setWakeMaximum(_ value: Float) {
        guard value.isFinite else { return }
        wakeMaximum = min(1, max(0, value))
        defaults.set(wakeMaximum, forKey: "audioWakeMaximum")
    }

    /// Keeps the previous wake behavior: the wake cap and an enabled device cap
    /// both apply, so the stricter ceiling wins. Never enables device limits.
    static func wakeLimit(defaultMaximum: Float, deviceMaximum: Float?) -> Float {
        min(defaultMaximum, deviceMaximum ?? defaultMaximum)
    }

    func applyWakeLimit(deviceLimitsEnabled: Bool) {
        guard let id = OutputAudio.defaultDevice(), let device = AudioDeviceAccess.describe(id) else { return }
        let limit = Self.wakeLimit(defaultMaximum: wakeMaximum, deviceMaximum: deviceLimitsEnabled ? rules[device.id]?.maximum : nil)
        var wakeEnforcer = ChannelVolumeLimitEnforcer()
        if let result = wakeEnforcer.enforce(maximum: limit, read: { OutputAudio.volumes(device: id) },
                                             write: { OutputAudio.capVolume($0, device: id) }) {
            report(result, name: device.name)
        } else if wakeEnforcer.verifiedWithinLimit {
            wakeStatus = .init(phase: .ready, message: "After wake, \(device.name) was already within the volume limit.")
        }
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
            for element in listenedElements {
                var address = OutputAudio.volumeAddress(element: element)
                AudioObjectRemovePropertyListenerBlock(listenedDevice, &address, queue, volumeListener)
            }
        }
        listenedDevice = nil
        listenedElements = []
    }

    private func deviceChanged() {
        guard active else { return }
        let previous = current
        detach()
        refreshDevices()
        guard let id = OutputAudio.defaultDevice(), let next = AudioDeviceAccess.describe(id) else { statusPhase = .waiting; status = "Waiting for an output device."; return }
        current = next
        statusPhase = rules[next.id] == nil ? .waiting : .ready
        status = rules[next.id] == nil ? "No enabled device limit for \(next.name)." : "Checking \(next.name) against its limit."
        enforcer.reset()
        if let previous, previous.id != next.id, rules[previous.id]?.muteOnSwitchAway == true {
            OutputAudio.setMuted(true, device: id)
        }
        if next.supportsVolume {
            listenedElements = OutputAudio.volumeElements(id)
            for element in listenedElements {
                var address = OutputAudio.volumeAddress(element: element)
                AudioObjectAddPropertyListenerBlock(id, &address, queue, volumeListener)
            }
            listenedDevice = id
        }
        enforce()
    }

    private func enforce() {
        guard active, let current, OutputAudio.defaultDevice() == current.device,
              let rule = rules[current.id] else { return }
        guard current.supportsVolume else {
            statusPhase = .blocked
            status = "\(current.name) uses its own hardware volume control."
            return
        }
        guard let result = enforcer.enforce(maximum: rule.maximum,
                                           read: { OutputAudio.volumes(device: current.device) },
                                           write: { OutputAudio.capVolume($0, device: current.device) }) else {
            if enforcer.verifiedWithinLimit {
                statusPhase = .ready
                status = "\(current.name) is within its volume limit; no change needed."
            }
            return
        }
        statusPhase = result.phase
        switch result {
        case .applied(let value): status = "Set \(current.name) to \(Int(value * 100))%, within its limit."
        case .rounded(let value): status = "\(current.name) reported \(Int(value * 100))%, above its limit. Use its hardware control."
        case .failed: status = "macOS couldn't change \(current.name)'s volume. Use its hardware control."
        case .unverified: status = "Could not verify \(current.name)'s volume after setting its limit."
        }
        onAction?(status)
    }

    private func report(_ result: VolumeLimitEnforcer.Result, name: String) {
        statusPhase = result.phase
        switch result {
        case .applied(let value): status = "After wake, limited \(name) to \(Int(value * 100))%."
        case .rounded: status = "After wake, \(name) rounded above its volume limit. Use its hardware control."
        case .failed: status = "Could not apply the wake volume limit to \(name)."
        case .unverified: status = "Could not verify the wake volume limit for \(name)."
        }
        wakeStatus = .init(phase: result.phase, message: status)
        onAction?(status)
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
        let supported = !OutputAudio.volumeElements(device).isEmpty
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
