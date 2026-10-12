import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: TweakSettings
    @Bindable var controller: TweakController
    @Bindable var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Form {
            if !controller.hasAccessibility {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Some tweaks need Accessibility permission", systemImage: "hand.raised")
                            .font(.headline)
                        Text("Clearing notifications, dismissing Shortcut banners, the green button and blocking Music read or click other apps' windows. Allow Tweaks in System Settings › Privacy & Security › Accessibility.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Accessibility Settings") {
                            AX.requestTrust()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Keyboard and sound") {
                row(.capsLockNoDelay)
                row(.wakeVolumeLimit)
                row(.muteIcon)
                row(.blockMusicLaunch)
            }

            Section("Downloads") {
                row(.lowercaseExtensions)
                row(.calendarInvites)
                row(.dmgInstaller)
            }

            Section("Windows and notifications") {
                row(.clearNotificationsHotKey)
                row(.dismissShortcutNotifications)
                row(.greenButtonFills)
                Button("Clear notifications now") { controller.clearNotifications() }
                    .disabled(!controller.hasAccessibility)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                Text("Tweaks has no menu bar icon. Open it again from Finder, Spotlight or Raycast to come back here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Quit Tweaks") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
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
