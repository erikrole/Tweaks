import AppKit
import CoreAudio
import XCTest
@testable import Tweaks

/// Regressions for the installed-app audit. No background tweaks are started.
@MainActor
final class VerificationRegressionTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let domain = "TweaksVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set([String](), forKey: "autoConnectShares")
        defer { defaults.removePersistentDomain(forName: domain) }
        body(defaults)
    }

    func testDisablingWorkSharesPreservesConfiguredServers() {
        withDefaults { defaults in
            let settings = TweakSettings(defaults: defaults)
            let urls = ["smb://audit.example.invalid/verification"]
            settings.setAutoShares(urls)
            settings.set(.autoConnectShares, on: false)
            XCTAssertEqual(TweakSettings(defaults: defaults).autoShares, urls)
        }
    }

    func testDisabledWorkSharesStayDisabledAcrossTwoRestarts() {
        withDefaults { defaults in
            let settings = TweakSettings(defaults: defaults)
            settings.set(.autoConnectShares, on: false)
            XCTAssertFalse(TweakSettings(defaults: defaults).isOn(.autoConnectShares))
            XCTAssertFalse(TweakSettings(defaults: defaults).isOn(.autoConnectShares))
        }
    }

    func testCapsLockAcceptsActualHidutilTableFormat() {
        // This Mac's hidutil output is a table, not the JSON used by the old test.
        let output = "RegistryID  Key                   Value\n100000b57   CapsLockDelayOverride   100000000\n"
        XCTAssertEqual(CapsLockDelay.parse(hidutilOutput: output), 100_000_000)
    }

    func testShortcutCollisionUsesPhysicalKeysNotDisplayLabel() throws {
        withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            let original = ShortcutAction.keepAwake.defaultShortcut!
            let recorded = Shortcut(keyCode: original.keyCode, modifiers: original.modifiers, key: "?")
            store.set(recorded, for: .screenOff)
            XCTAssertNil(store.shortcut(for: .keepAwake))
        }
    }

    func testDMGInstallerRejectsSiblingOfDownloads() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads-Archive/App.dmg").path
        let info: [String: Any] = ["images": [["image-path": path, "system-entities": [["mount-point": "/Volumes/Audit"]]]]]
        XCTAssertNil(DMGInstaller.imagePath(for: "/Volumes/Audit", inHdiutilInfo: info))
    }

    func testSettingsWindowCanBeConstructed() {
        withDefaults { defaults in
            let settings = TweakSettings(defaults: defaults)
            let controller = TweakController(defaults: defaults)
            controller.settings = settings
            // Do not call controller.start(): no background tweaks are activated.
            let window = SettingsWindowController(settings: settings, tweaks: controller, launchAtLogin: LaunchAtLoginController())
            XCTAssertNotNil(window.window?.contentView)
            window.close()
        }
    }
}
