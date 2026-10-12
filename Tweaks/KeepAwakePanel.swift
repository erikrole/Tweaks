import AppKit
import Observation
import SwiftUI

/// The Keep Awake chooser: a floating panel centered near the top of the screen you're
/// on, like Raycast. Arrow keys move, Return picks, number keys pick a duration, letters
/// toggle options, Esc closes, and clicking elsewhere dismisses it.
@MainActor
final class KeepAwakePanelController {
    static let shared = KeepAwakePanelController()

    private var panel: KeyablePanel?
    private var model: PanelModel?

    static let durations: [(key: String, hours: Double)] = [("1", 1), ("2", 2), ("3", 4), ("4", 8), ("5", 12)]

    func toggle(_ keepAwake: KeepAwake) {
        if panel?.isVisible == true { close() } else { show(keepAwake) }
    }

    func show(_ keepAwake: KeepAwake) {
        close()
        let model = PanelModel(keepAwake: keepAwake)
        model.onDone = { [weak self] in self?.close() }
        self.model = model

        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: KeepAwakePanelView(model: model))
        let size = panel.contentView?.fittingSize ?? NSSize(width: 560, height: 360)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.25 - size.height,
                                  width: size.width, height: size.height), display: true)
        }
        panel.onKey = { [weak model] characters, keyCode in model?.handleKey(characters, keyCode: keyCode) ?? false }
        panel.onResignKey = { [weak self] in self?.close() }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}

/// One choice in the panel.
struct PanelItem: Identifiable {
    let id: String
    let title: String
    var key: String?
    var symbol: String?
    var icon: NSImage?
    var prominent = false
    let run: @MainActor (KeepAwake) -> Void
}

struct PanelSection: Identifiable {
    let id: String
    let title: String
    let items: [PanelItem]
}

/// The panel's choices and keyboard selection.
@MainActor
@Observable
final class PanelModel {
    let keepAwake: KeepAwake
    private(set) var sections: [PanelSection] = []
    var selection: String
    var onDone: (() -> Void)?

    init(keepAwake: KeepAwake) {
        self.keepAwake = keepAwake
        selection = "hours-12"
        sections = buildSections()
    }

    private var allItems: [PanelItem] { sections.flatMap(\.items) }

    private func buildSections() -> [PanelSection] {
        var sections: [PanelSection] = []
        let recent = keepAwake.recents.compactMap { choice -> PanelItem? in
            if case let .app(bundleID, _) = choice, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                return nil // the app isn't open, so "until it quits" can't apply
            }
            return PanelItem(id: "recent-\(choice.title)", title: choice.title, symbol: "clock.arrow.circlepath") { $0.start(choice) }
        }
        if !recent.isEmpty { sections.append(PanelSection(id: "recent", title: "Recent", items: recent)) }

        sections.append(PanelSection(id: "for", title: "For", items: KeepAwakePanelController.durations.map { duration in
            PanelItem(id: "hours-\(Int(duration.hours))", title: duration.hours == 1 ? "1 hour" : "\(Int(duration.hours)) hours",
                      key: duration.key, prominent: duration.hours == 12) { $0.start(Choice.hours(duration.hours)) }
        }))

        sections.append(PanelSection(id: "done", title: "Until it's done", items: JobCondition.allCases.map { job in
            PanelItem(id: "done-\(job.rawValue)", title: job.title, symbol: job.symbol) { $0.start(Choice.done(job)) }
        }))

        let times = KeepAwake.suggestedEndTimes(from: Date()).prefix(4)
        if !times.isEmpty {
            sections.append(PanelSection(id: "until", title: "Until", items: times.map { time in
                PanelItem(id: "time-\(time.timeIntervalSince1970)", title: time.formatted(date: .omitted, time: .shortened)) {
                    $0.start(.date(time))
                }
            }))
        }

        let apps = KeepAwake.candidateApps().prefix(5)
        if !apps.isEmpty {
            sections.append(PanelSection(id: "apps", title: "Until an app quits", items: apps.map { app in
                let name = app.localizedName ?? "App"
                return PanelItem(id: "app-\(app.processIdentifier)", title: name, icon: app.icon) { keepAwake in
                    if let bundleID = app.bundleIdentifier {
                        keepAwake.start(Choice.app(bundleID: bundleID, name: name))
                    } else {
                        keepAwake.start(.appQuits(pid: app.processIdentifier, name: name))
                    }
                }
            }))
        }

        var tail = [PanelItem(id: "indefinitely", title: "Indefinitely", key: "I") { $0.start(Choice.indefinitely) }]
        if keepAwake.session != nil {
            tail.append(PanelItem(id: "stop", title: "Stop", key: "S", symbol: "stop.circle") { $0.stop(reason: "Stopped.") })
        }
        sections.append(PanelSection(id: "more", title: "More", items: tail))
        return sections
    }

    func run(_ item: PanelItem) {
        item.run(keepAwake)
        onDone?()
    }

    // MARK: Keyboard

    func handleKey(_ characters: String, keyCode: UInt16) -> Bool {
        switch keyCode {
        case 53: onDone?(); return true // Esc
        case 36, 76: // Return, Enter
            if let item = allItems.first(where: { $0.id == selection }) { run(item) }
            return true
        case 123: move(by: -1); return true // ←
        case 124: move(by: 1); return true // →
        case 125: moveSection(by: 1); return true // ↓
        case 126: moveSection(by: -1); return true // ↑
        default: break
        }
        let key = characters.lowercased()
        if let item = allItems.first(where: { $0.key?.lowercased() == key }) {
            run(item)
            return true
        }
        switch key {
        case "d": keepAwake.setKeepsDisplayOn(!displayOn); return true
        case "p": keepAwake.setOnlyOnPower(!onlyOnPower); return true
        default: return false
        }
    }

    private func move(by step: Int) {
        let items = allItems
        guard let index = items.firstIndex(where: { $0.id == selection }) else { return }
        selection = items[(index + step + items.count) % items.count].id
    }

    private func moveSection(by step: Int) {
        guard let sectionIndex = sections.firstIndex(where: { $0.items.contains { $0.id == selection } }),
              let itemIndex = sections[sectionIndex].items.firstIndex(where: { $0.id == selection })
        else { return }
        let target = sections[(sectionIndex + step + sections.count) % sections.count]
        selection = target.items[min(itemIndex, target.items.count - 1)].id
    }

    var displayOn: Bool { keepAwake.session?.keepsDisplayOn ?? keepAwake.keepsDisplayOnByDefault }
    var onlyOnPower: Bool { keepAwake.session?.onlyOnPower ?? keepAwake.onlyOnPowerByDefault }
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
    @Bindable var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(model.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FlowRow(spacing: 6) {
                        ForEach(section.items) { item in
                            Chip(item: item, selected: model.selection == item.id) { model.run(item) }
                                .onHover { if $0 { model.selection = item.id } }
                        }
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                Toggle(title: model.displayOn ? "Display stays on" : "Display can sleep", key: "D", isOn: model.displayOn) {
                    model.keepAwake.setKeepsDisplayOn(!model.displayOn)
                }
                Toggle(title: "Only while plugged in", key: "P", isOn: model.onlyOnPower) {
                    model.keepAwake.setOnlyOnPower(!model.onlyOnPower)
                }
                Spacer()
                Text("←→↑↓ move · ⏎ start · esc close")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(width: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .padding(1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.keepAwake.session == nil ? "cup.and.saucer" : "cup.and.saucer.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(model.keepAwake.session == nil ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep Awake").font(.system(size: 15, weight: .semibold))
                Text(model.keepAwake.session == nil ? "Return keeps it awake for 12 hours" : model.keepAwake.statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct Chip: View {
    let item: PanelItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let key = item.key { KeyCap(key) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.orange.opacity(0.3) : Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.orange : (item.prominent ? Color.orange.opacity(0.5) : Color.white.opacity(0.06))))
            .foregroundStyle(item.id == "stop" ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct Toggle: View {
    let title: String
    let key: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.orange : Color.secondary)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                KeyCap(key)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
    }
}

/// Lays chips out left to right, wrapping onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 540
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
