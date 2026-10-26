import AppKit
import AppUpdater

/// One updater for the lifetime of the host.
@MainActor
enum AppUpdate {
    static var busyReason: @MainActor @Sendable () -> String? = { nil }
    static let updater = AppUpdater(.init(
        repository: "erikrole/Tweaks", assetName: "Tweaks.zip",
        busyReason: { busyReason() }, postUpdate: .quiet,
        autoInstall: { UserDefaults.standard.object(forKey: autoUpdateKey) as? Bool ?? true }
    ))

    /// The Settings switch; on unless turned off.
    nonisolated static let autoUpdateKey = "autoUpdate"

    static var isPreparing: Bool { updater.isInstalling && !updater.isAwaitingRelaunch }

    static func checkOnLaunch() {
        #if !DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        updater.checkOnLaunch()
        #endif
    }

    static func checkNow() { updater.checkNow() }
}
