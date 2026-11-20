import AppKit
import AppUpdater
import Observation

/// One updater for the lifetime of the host.
@MainActor
enum AppUpdate {
    @Observable final class MenuState {
        var title = "Check for Updates…"
        var availableVersion: String?
        var statusText: String?
    }

    static let menuState = MenuState()
    static var busyReason: @MainActor @Sendable () -> String? = { nil }
    static let updater: AppUpdater = {
        let updater = AppUpdater(.init(
            repository: "erikrole/Tweaks", assetName: "Tweaks.zip",
            busyReason: { busyReason() }, postUpdate: .quiet,
            autoInstall: { UserDefaults.standard.object(forKey: autoUpdateKey) as? Bool ?? true },
            installOnQuit: { UserDefaults.standard.bool(forKey: installOnQuitKey) }
        ))
        updater.onStateChange = { state in refreshMenuState(state) }
        return updater
    }()

    /// The Settings switches; auto-update is on unless turned off, install-on-quit is opt-in.
    nonisolated static let autoUpdateKey = "autoUpdate"
    nonisolated static let installOnQuitKey = "installUpdatesOnQuit"

    static var isPreparing: Bool { updater.isInstalling && !updater.isAwaitingRelaunch }
    static var menuTitle: String { updater.menuTitle ?? "Check for Updates…" }

    static var currentVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.11"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? "Tweaks \(short)" : "Tweaks \(short) (\(build))"
    }

    static func attach(hostView: NSView?) {
        updater.hostView = hostView
        refreshMenuState(updater.state)
    }

    private static func refreshMenuState(_ state: AppUpdater.State) {
        let nextTitle = updater.menuTitle ?? "Check for Updates…"
        if menuState.title != nextTitle { menuState.title = nextTitle }
        let nextVersion: String? = switch state {
        case .ready(let version), .available(let version), .updating(let version): version
        case .idle, .failed: nil
        }
        if menuState.availableVersion != nextVersion { menuState.availableVersion = nextVersion }
        let nextStatus: String? = switch state {
        case .idle: nil
        case .updating(let version): "Downloading update \(version)…"
        case .ready(let version): "Version \(version) is ready to install."
        case .available(let version): "Version \(version) is available."
        case .failed(let message): message
        }
        if menuState.statusText != nextStatus { menuState.statusText = nextStatus }
    }

    static func checkOnLaunch() {
        #if !DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        updater.checkOnLaunch()
        #endif
    }

    static func performMenuAction() { updater.performMenuAction() }
    static func checkNow() { updater.checkNow() }
}
