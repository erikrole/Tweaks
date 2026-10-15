import AppKit
import FinderSync
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: TweakSettings
    @Bindable var controller: TweakController
    @Bindable var launchAtLogin: LaunchAtLoginController
    @State private var newShare = ""

    var body: some View {
        Form {
            if !controller.hasAccessibility {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Some tweaks need Accessibility permission", systemImage: "hand.raised")
                            .font(.headline)
                        Text("Window layouts, clearing notifications, dismissing Shortcut banners, the green button and blocking Music read or control other apps' windows. Allow Tweaks in System Settings › Privacy & Security › Accessibility.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Accessibility Settings") {
                                AX.requestTrust()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Button("Already on? Relaunch Tweaks") { AX.relaunch() }
                        }
                        Text("If Tweaks is switched on there and this still shows, macOS is holding an old answer; relaunching picks it up. If it's still stuck, remove Tweaks from the list with the minus button and add it again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Shortcuts") {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(shortcut: controller.shortcuts.shortcut(for: action)) { shortcut in
                            controller.shortcuts.set(shortcut, for: action)
                        }
                    }
                }
                Text("Click a shortcut, then press the new keys (⌫ removes it, Esc cancels). Hyper is ⌃⌥⇧⌘.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard and sound") {
                row(.capsLockNoDelay)
                row(.wakeVolumeLimit)
                row(.muteIcon)
                row(.blockMusicLaunch)
                row(.deviceVolumeLimits)
                VolumeLimitsSettings(model: controller.volumeLimits)
            }

            Section("Downloads and clipboard") {
                row(.lowercaseExtensions)
                row(.calendarInvites)
                row(.dmgInstaller)
                row(.unzipDownloads)
                row(.cleanCopiedLinks)
                row(.duplicateDownloads)
                DuplicateReviewSettings(model: controller.duplicates)
            }

            Section("Sleep") {
                row(.keepAwakeHotKey)
                SwiftUI.Toggle("Show time left next to the cup", isOn: Binding(
                    get: { controller.keepAwake.showsCountdown },
                    set: { controller.keepAwake.showsCountdown = $0 }
                ))
                    .font(.callout)
                if controller.keepAwake.session != nil {
                    HStack {
                        Label(controller.keepAwake.statusLine, systemImage: "cup.and.saucer.fill")
                            .font(.caption)
                        Spacer()
                        Button("Stop") { controller.keepAwake.stop() }.buttonStyle(.link)
                    }
                }
                row(.ejectBeforeSleep)
                row(.safeEjectHotKey)
                HStack {
                    Button("Eject Idle External Drives") { Task { await controller.safeEject.ejectIdleDrives() } }
                        .disabled(controller.safeEject.busy)
                    if controller.safeEject.busy { ProgressView().controlSize(.small) }
                }
                ForEach(controller.safeEject.results, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                row(.awakeWhileRendering)
                if let holding = controller.renderAwake.holdingFor {
                    Label("Keeping your Mac awake: \(holding) is rendering", systemImage: "cup.and.saucer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Windows and notifications") {
                row(.clearNotificationsHotKey)
                row(.dismissShortcutNotifications)
                row(.greenButtonFills)
                row(.windowLayouts)
                HStack {
                    Button("Save This Layout") { Task { await controller.windowLayouts.save() } }
                    Button("Restore Layout") { Task { await controller.windowLayouts.restore() } }
                    Button("Forget Layout") { controller.windowLayouts.forgetCurrent() }
                }
                .disabled(!settings.isOn(.windowLayouts) || !controller.hasAccessibility || controller.windowLayouts.busy)
                Text(controller.windowLayouts.status).font(.caption).foregroundStyle(.secondary)
                Button("Clear notifications now") { controller.clearNotifications() }
                    .disabled(!controller.hasAccessibility)
            }

            Section("Network") {
                row(.unmountSharesBeforeSleep)
                row(.autoConnectShares)
                ForEach(settings.autoShares, id: \.self) { share in
                    HStack {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        Text(share).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { settings.setAutoShares(settings.autoShares.filter { $0 != share }) }
                            .buttonStyle(.link)
                    }
                }
                HStack {
                    TextField("smb://server/share", text: $newShare)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addShare)
                    Button("Add", action: addShare)
                        .disabled(URL(string: newShare)?.host() == nil)
                }
            }

            Section("Finder") {
                Button("Quick Image Actions…") { controller.imageActions.choose() }
                Text("Convert or resize selected images and optionally remove metadata. Originals are kept. Also available from Finder's right-click menu.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finder Utilities")
                    Text("Adds Copy Path (with NAS, Box and Google Drive roots shortened), Copy Original Path and Inspect Media to Finder's right-click menu. Turn it on under Finder Extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Label(FIFinderSyncController.isExtensionEnabled ? "On in Finder" : "Off in Finder",
                          systemImage: FIFinderSyncController.isExtensionEnabled ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(FIFinderSyncController.isExtensionEnabled ? .green : .secondary)
                    Spacer()
                    Button("Finder Extensions Settings…") { FIFinderSyncController.showExtensionManagementInterface() }
                }
            }

            Section("Quit when the last window closes") {
                row(.quitOnLastWindow)
                ForEach(settings.quitApps, id: \.self) { bundleID in
                    HStack {
                        Text(Self.appName(for: bundleID))
                        Spacer()
                        Button("Remove") {
                            settings.setQuitApps(settings.quitApps.filter { $0 != bundleID })
                        }
                        .buttonStyle(.link)
                    }
                }
                Button("Add App…") { addQuitApp() }
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                Text("Tweaks keeps running after you close this window, with no Dock or menu bar icon. Open it again from Finder or Spotlight to come back here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Quit Tweaks") {
                        AppDelegate.reallyQuit = true
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
    }

    private func addShare() {
        let trimmed = newShare.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.host() != nil, !settings.autoShares.contains(trimmed) else { return }
        settings.setAutoShares(settings.autoShares + [trimmed])
        newShare = ""
    }

    private func addQuitApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        settings.setQuitApps(Array(Set(settings.quitApps + added)).sorted { Self.appName(for: $0) < Self.appName(for: $1) })
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func row(_ tweak: Tweak) -> some View {
        Toggle(isOn: Binding(get: { settings.isOn(tweak) }, set: { settings.set(tweak, on: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tweak.title)
                Text(tweak.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if tweak.needsAccessibility && !controller.hasAccessibility && settings.isOn(tweak) {
                    Text("Waiting for Accessibility permission")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
