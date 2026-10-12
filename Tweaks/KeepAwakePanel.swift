import AppKit
import SwiftUI

/// The Keep Awake chooser: a floating panel centered near the top of the screen you're
/// on, like Raycast. Number keys pick a duration, letters the rest, Esc closes, and
/// clicking elsewhere dismisses it.
@MainActor
final class KeepAwakePanelController {
    static let shared = KeepAwakePanelController()

    private var panel: KeyablePanel?

    struct Option: Identifiable {
        let id: String
        let key: String
        let title: String
        let action: @MainActor (KeepAwake) -> Void
    }

    static let durations: [(key: String, title: String, hours: Double)] = [
        ("1", "1 hour", 1), ("2", "2 hours", 2), ("3", "4 hours", 4), ("4", "8 hours", 8), ("5", "12 hours", 12),
    ]

    func toggle(_ keepAwake: KeepAwake) {
        if panel?.isVisible == true { close() } else { show(keepAwake) }
    }

    func show(_ keepAwake: KeepAwake) {
        close()
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let view = KeepAwakePanelView(
            keepAwake: keepAwake,
            times: KeepAwake.suggestedEndTimes(from: Date()).prefix(4).map { $0 },
            apps: Array(KeepAwake.candidateApps().prefix(5)),
            choose: { [weak self] action in
                action(keepAwake)
                self?.close()
            },
            close: { [weak self] in self?.close() }
        )
        panel.contentView = NSHostingView(rootView: view)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 420, height: 300)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.28 - size.height,
                                  width: size.width, height: size.height), display: true)
        }
        panel.onKey = { [weak self] characters, keyCode in
            self?.handleKey(characters, keyCode: keyCode, keepAwake: keepAwake) ?? false
        }
        panel.onResignKey = { [weak self] in self?.close() }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func handleKey(_ characters: String, keyCode: UInt16, keepAwake: KeepAwake) -> Bool {
        if keyCode == 53 { close(); return true } // Esc
        let key = characters.lowercased()
        if let duration = Self.durations.first(where: { $0.key == key }) {
            keepAwake.start(.date(Date().addingTimeInterval(duration.hours * 3600)))
            close()
            return true
        }
        switch key {
        case "i":
            keepAwake.start(.indefinitely)
        case "d":
            keepAwake.setKeepsDisplayOn(!(keepAwake.session?.keepsDisplayOn ?? keepAwake.keepsDisplayOnByDefault))
            return true // stay open so you can pick a duration next
        case "s" where keepAwake.session != nil:
            keepAwake.stop(reason: "Stopped.")
        case "\r":
            keepAwake.start(.date(Date().addingTimeInterval(KeepAwake.defaultDuration)))
        default:
            return false
        }
        close()
        return true
    }
}

/// A borderless panel that can take keyboard focus without activating Tweaks.
final class KeyablePanel: NSPanel {
    var onKey: ((String, UInt16) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event.charactersIgnoringModifiers ?? "", event.keyCode) != true {
            super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

private struct KeepAwakePanelView: View {
    @Bindable var keepAwake: KeepAwake
    let times: [Date]
    let apps: [NSRunningApplication]
    let choose: (@MainActor (KeepAwake) -> Void) -> Void
    let close: () -> Void

    private var displayOn: Bool { keepAwake.session?.keepsDisplayOn ?? keepAwake.keepsDisplayOnByDefault }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            section("For") {
                HStack(spacing: 6) {
                    ForEach(KeepAwakePanelController.durations, id: \.key) { duration in
                        Chip(title: duration.title, key: duration.key, prominent: duration.hours == 12) {
                            choose { $0.start(.date(Date().addingTimeInterval(duration.hours * 3600))) }
                        }
                    }
                }
            }

            if !times.isEmpty {
                section("Until") {
                    HStack(spacing: 6) {
                        ForEach(times, id: \.self) { time in
                            Chip(title: time.formatted(date: .omitted, time: .shortened)) {
                                choose { $0.start(.date(time)) }
                            }
                        }
                    }
                }
            }

            if !apps.isEmpty {
                section("Until an app quits") {
                    HStack(spacing: 6) {
                        ForEach(apps, id: \.processIdentifier) { app in
                            Chip(title: app.localizedName ?? "App", icon: app.icon) {
                                choose { $0.start(.appQuits(pid: app.processIdentifier, name: app.localizedName ?? "The app")) }
                            }
                        }
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 6) {
                Chip(title: "Indefinitely", key: "I") { choose { $0.start(.indefinitely) } }
                Chip(title: displayOn ? "Display stays on" : "Display can sleep", key: "D", isOn: displayOn) {
                    keepAwake.setKeepsDisplayOn(!displayOn)
                }
                Spacer()
                if keepAwake.session != nil {
                    Chip(title: "Stop", key: "S", destructive: true) { choose { $0.stop(reason: "Stopped.") } }
                }
            }
        }
        .padding(18)
        .frame(width: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThickMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .padding(1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: keepAwake.session == nil ? "cup.and.saucer" : "cup.and.saucer.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(keepAwake.session == nil ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep Awake").font(.system(size: 15, weight: .semibold))
                Text(keepAwake.session == nil ? "Return keeps it awake for 12 hours" : keepAwake.statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("esc").font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                .foregroundStyle(.secondary)
                .onTapGesture(perform: close)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct Chip: View {
    let title: String
    var key: String?
    var icon: NSImage?
    var prominent = false
    var isOn = false
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let key {
                    Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(prominent ? Color.orange.opacity(0.7) : Color.white.opacity(0.06)))
            .foregroundStyle(destructive ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isOn { return Color.orange.opacity(0.25) }
        return Color.white.opacity(hovering ? 0.14 : 0.06)
    }
}
