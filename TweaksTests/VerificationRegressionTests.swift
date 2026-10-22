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

    func testNativeSettingsPreserveAllChoicesAndExposeEveryTweakAndShortcut() {
        let domain = "NativeSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set([String](), forKey: TweakSettings.shareURLsKey)
        defer { defaults.removePersistentDomain(forName: domain) }
        do {
            let settings = TweakSettings(defaults: defaults)
            settings.set(.calendarInvites, on: false)
            settings.set(.deviceVolumeLimits, on: true)
            let controller = TweakController(defaults: defaults)
            controller.settings = settings
            let before = defaults.persistentDomain(forName: domain)! as NSDictionary
            let window = SettingsWindowController(settings: settings, tweaks: controller, launchAtLogin: LaunchAtLoginController())
            defer { window.close() }
            XCTAssertNil(window.window?.appearance)
            XCTAssertTrue(window.window!.styleMask.contains(.resizable))
            XCTAssertEqual(Set(window.toggles.keys), Set(Tweak.allCases))
            XCTAssertEqual(Set(window.recorders.keys), Set(ShortcutAction.allCases))
            for pane in SettingsTab.allCases { window.selectPane(pane); window.sync() }
            for (tweak, checkbox) in window.toggles {
                XCTAssertEqual(checkbox.state == .on, settings.isOn(tweak))
                XCTAssertEqual(checkbox.title, tweak.title)
            }
            XCTAssertEqual(defaults.persistentDomain(forName: domain)! as NSDictionary, before)
        }
    }

    func testSettingsPagesHaveUsableGeometryBeforeAndAfterDisplay() {
        withDefaults { defaults in
            let settings = TweakSettings(defaults: defaults)
            settings.setAutoShares(["smb://example.invalid/a-long-share-name"])
            let controller = TweakController(defaults: defaults)
            controller.settings = settings
            let settingsWindow = SettingsWindowController(settings: settings, tweaks: controller,
                                                          launchAtLogin: LaunchAtLoginController())
            defer { settingsWindow.close() }
            let root = settingsWindow.window!.contentView!
            @MainActor func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let scroll = descendants(root).compactMap { $0 as? NSScrollView }.first { $0.identifier?.rawValue == "settings-content" }!
            let categories = descendants(root).compactMap { $0 as? NSTableView }.first!
            @MainActor func checkGeometry() {
                root.layoutSubtreeIfNeeded()
                let page = scroll.documentView as! SettingsPage
                page.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(page.frame.width, 400)
                XCTAssertGreaterThan(page.frame.height, 1)
                XCTAssertEqual(page.column.frame.width, page.frame.width, accuracy: 0.5)
                XCTAssertGreaterThan(page.column.frame.height, 1)
                XCTAssertGreaterThanOrEqual(page.frame.height + 0.5, page.column.fittingSize.height)
                XCTAssertFalse(page.column.hasAmbiguousLayout)
                for view in descendants(page) where !view.isHiddenOrHasHiddenAncestor {
                    XCTAssertTrue(view.frame.width.isFinite && view.frame.height.isFinite)
                    XCTAssertGreaterThanOrEqual(view.frame.width, 0)
                    XCTAssertGreaterThanOrEqual(view.frame.height, 0)
                }
            }
            checkGeometry()
            settingsWindow.showWindow(nil)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                settingsWindow.window?.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 760, height: 540), NSSize(width: 960, height: 760)] {
                    settingsWindow.window?.setContentSize(size)
                    for tab in SettingsTab.allCases {
                        categories.selectRowIndexes(IndexSet(integer: tab.rawValue), byExtendingSelection: false)
                        settingsWindow.sync()
                        XCTAssertEqual(settingsWindow.selectedPane, tab)
                        checkGeometry()
                        if tab == .sleep {
                            for choice in [SessionEndChoice.time, .appQuits, .indefinitely] {
                                settingsWindow.awakeEnd.choice.selectItem(at: choice.rawValue)
                                settingsWindow.awakeEnd.changed()
                                // Measure the expanded variant before asserting its geometry.
                                settingsWindow.selectPane(tab)
                                checkGeometry()
                            }
                        }
                        if let output = ProcessInfo.processInfo.environment["TWEAKS_SETTINGS_CAPTURE_DIR"], size.width == 960,
                           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                            root.displayIfNeeded()
                            root.cacheDisplay(in: root.bounds, to: bitmap)
                            // cacheDisplay omits the window's opaque background.
                            let image = NSImage(size: root.bounds.size)
                            image.lockFocus()
                            settingsWindow.window!.effectiveAppearance.performAsCurrentDrawingAppearance {
                                NSColor.windowBackgroundColor.setFill()
                                root.bounds.fill()
                                let snapshot = NSImage(size: root.bounds.size)
                                snapshot.addRepresentation(bitmap)
                                snapshot.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                            }
                            image.unlockFocus()
                            let composed = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
                            let folder = URL(filePath: output)
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let name = "\(appearance.rawValue)-\(tab.rawValue).png"
                            try? composed?.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name))
                        }
                    }
                }
            }
        }
    }
}
