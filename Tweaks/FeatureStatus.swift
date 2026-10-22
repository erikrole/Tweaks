import Foundation

/// An execution snapshot, separate from the user's saved enable switch.
struct FeatureRuntime: Equatable, Sendable {
    enum Phase: String, Sendable {
        case off = "Off", ready = "Ready", working = "Working", active = "Active"
        case waiting = "Waiting", paused = "Paused", blocked = "Blocked"
    }
    var phase: Phase
    var message: String
    var finishingRecovery = false
    var text: String { message.isEmpty ? phase.rawValue : "\(phase.rawValue) · \(message)" }

    static func resolve(enabled: Bool, pausedUntil: Date? = nil, needsAccess: Bool = false,
                        hasAccess: Bool = true, runtime: FeatureRuntime) -> FeatureRuntime {
        guard enabled else {
            return runtime.finishingRecovery ? runtime : .init(phase: .off, message: "Saved setting is off.")
        }
        if let pausedUntil {
            return .init(phase: .paused, message: "Until \(pausedUntil.formatted(date: .omitted, time: .shortened)).")
        }
        if needsAccess && !hasAccess { return .init(phase: .blocked, message: "Allow Accessibility in System Settings.") }
        return runtime
    }
}

extension TweakController {
    func featureStatus(for tweak: Tweak) -> FeatureRuntime {
        var runtime = runtimeStatuses[tweak] ?? .init(phase: .ready, message: "Enabled; waiting for its trigger.")
        switch tweak {
        case .wakeVolumeLimit: runtime = volumeLimits.wakeStatus ?? .init(phase: .ready, message: "Applies the maximum after waking.")
        case .deviceVolumeLimits:
            runtime = volumeLimits.rules.isEmpty
                ? .init(phase: .waiting, message: "Choose a limit for an output device.")
                : .init(phase: volumeLimits.statusPhase, message: volumeLimits.status)
        case .awakeWhileRendering:
            runtime = renderAwake.holdingFor.map { .init(phase: .active, message: "Keeping awake for \($0).") }
                ?? .init(phase: .ready, message: "Watching supported renderers.")
        case .keepAwakeHotKey:
            if keepAwake.session != nil { runtime = .init(phase: keepAwake.session?.pausedOnBattery == true ? .paused : .active, message: keepAwake.statusLine) }
            else { runtime = shortcutStatus([.keepAwake, .keepAwakePanel, .screenOff]) }
        case .clearNotificationsHotKey: runtime = shortcutStatus([.clearNotifications])
        case .safeEjectHotKey: runtime = safeEject.busy ? .init(phase: .working, message: "Checking and ejecting idle drives.") : shortcutStatus([.safeEject])
        case .quitOnLastWindow:
            if settings?.quitApps.isEmpty != false { runtime = .init(phase: .waiting, message: "Add an app to watch.") }
        case .windowLayouts: runtime = .init(phase: windowLayouts.busy ? .working : windowLayouts.statusPhase, message: windowLayouts.status)
        case .autoConnectShares:
            if settings?.autoShares.isEmpty != false { runtime = .init(phase: .waiting, message: "Add a work share.") }
        default: break
        }
        return .resolve(enabled: settings?.isOn(tweak) == true,
                        pausedUntil: Self.pausableTweaks.contains(tweak) ? automationPause.until : nil,
                        needsAccess: tweak.needsAccessibility, hasAccess: hasAccessibility, runtime: runtime)
    }

    private func shortcutStatus(_ actions: [ShortcutAction]) -> FeatureRuntime {
        let assigned = actions.filter { shortcuts.shortcut(for: $0) != nil }
        if let error = assigned.compactMap({ shortcutErrors[$0] }).first { return .init(phase: .blocked, message: error) }
        guard !assigned.isEmpty else { return .init(phase: .waiting, message: "Assign a shortcut under Shortcuts.") }
        return .init(phase: .ready, message: "Uses your assigned shortcuts.")
    }
}


extension VolumeLimitEnforcer.Result {
    var phase: FeatureRuntime.Phase {
        switch self {
        case .applied: .ready
        case .rounded, .failed, .unverified: .blocked
        }
    }
}
