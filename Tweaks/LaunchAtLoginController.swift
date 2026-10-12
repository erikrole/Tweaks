import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?

    private let service = SMAppService.mainApp
    private let defaults = UserDefaults.standard

    init() {
        status = service.status
        guard !Self.isRunningTests else { return }
        let storedPreference = defaults.object(forKey: LaunchAtLoginPolicy.preferenceKey) as? Bool
        guard let desiredEnabled = LaunchAtLoginPolicy.desiredEnabled(
            storedPreference: storedPreference,
            serviceStatus: status
        ) else {
            errorMessage = "Launch at Login is unavailable."
            return
        }
        if storedPreference == nil {
            defaults.set(desiredEnabled, forKey: LaunchAtLoginPolicy.preferenceKey)
        }
        desiredEnabled ? enable() : disable()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var statusText: String {
        switch status {
        case .enabled: "On"
        case .requiresApproval: "Needs approval"
        case .notRegistered: "Off"
        case .notFound: "Unavailable"
        @unknown default: "Unknown"
        }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: LaunchAtLoginPolicy.preferenceKey)
        enabled ? enable() : disable()
    }

    func refresh() {
        status = service.status
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func enable() {
        refresh()
        if status == .enabled {
            errorMessage = nil
            return
        }
        if status == .requiresApproval {
            errorMessage = "Tweaks needs approval in Login Items."
            return
        }
        do {
            try service.register()
            refresh()
            errorMessage = status == .enabled ? nil : "Tweaks needs approval in Login Items."
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    private func disable() {
        refresh()
        guard status != .notRegistered, status != .notFound else {
            errorMessage = nil
            return
        }
        do {
            try service.unregister()
            refresh()
            errorMessage = nil
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

enum LaunchAtLoginPolicy {
    static let preferenceKey = "launchAtLoginEnabled"

    static func desiredEnabled(
        storedPreference: Bool?,
        serviceStatus: SMAppService.Status
    ) -> Bool? {
        if let storedPreference { return storedPreference }
        switch serviceStatus {
        case .enabled:
            return true
        case .notRegistered, .requiresApproval:
            return false
        case .notFound:
            return nil
        @unknown default:
            return nil
        }
    }
}
