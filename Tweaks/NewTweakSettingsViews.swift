import AppKit
import SwiftUI

struct VolumeLimitsSettings: View {
    @Bindable var model: DeviceVolumeLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output device limits").font(.callout)
                Spacer()
                Button("Refresh Devices") { model.refreshDevices() }.buttonStyle(.link)
            }
            ForEach(model.devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(device.name, isOn: Binding(
                        get: { model.rules[device.id] != nil },
                        set: { enabled in model.setRule(enabled ? .init(name: device.name, maximum: 0.4) : nil, for: device.id) }
                    )).disabled(!device.supportsVolume && model.rules[device.id] == nil)
                    if let rule = model.rules[device.id] {
                        HStack {
                            Slider(value: Binding(get: { Double(model.rules[device.id]?.maximum ?? rule.maximum) },
                                                  set: { value in update(device, maximum: Float(value)) }), in: 0...1, step: 0.05)
                            Text("\(Int((model.rules[device.id]?.maximum ?? rule.maximum) * 100))%").monospacedDigit().frame(width: 42)
                        }.disabled(!device.supportsVolume)
                        Toggle("Mute the next output when switching away from this device", isOn: Binding(
                            get: { model.rules[device.id]?.muteOnSwitchAway ?? false },
                            set: { value in
                                var edited = model.rules[device.id] ?? rule
                                edited.muteOnSwitchAway = value
                                model.setRule(edited, for: device.id)
                            }
                        )).font(.caption)
                    }
                    if !device.supportsVolume { Text("Uses its own hardware volume control.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            ForEach(model.rules.keys.filter { uid in !model.devices.contains(where: { $0.id == uid }) }.sorted(), id: \.self) { uid in
                HStack {
                    Text("\(model.rules[uid]?.name ?? uid) · disconnected").font(.caption)
                    Spacer()
                    Button("Forget") { model.setRule(nil, for: uid) }.buttonStyle(.link)
                }
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }.task { model.refreshDevices() }
    }

    private func update(_ device: AudioOutputDevice, maximum: Float) {
        var rule = model.rules[device.id] ?? .init(name: device.name, maximum: maximum)
        rule.maximum = maximum
        model.setRule(rule, for: device.id)
    }
}

struct DuplicateReviewSettings: View {
    @Bindable var model: DuplicateReview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            ForEach(model.matches) { match in
                VStack(alignment: .leading, spacing: 5) {
                    Text("New: \(match.newFile.lastPathComponent)").font(.callout)
                    Text("Matches: \(match.existingFile.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: match.bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Show Both") { NSWorkspace.shared.activateFileViewerSelecting([match.newFile, match.existingFile]) }
                        Button("Keep Both") { model.keep(match) }
                        Button("Trash New Copy", role: .destructive) { Task { await model.trash(match) } }
                    }.disabled(model.busy)
                }
            }
        }
    }
}
