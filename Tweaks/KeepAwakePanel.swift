import AppKit
import Observation

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
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        let root = KeepAwakePanelRoot(model: model)
        panel.contentView = root
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize.width > 1 ? root.fittingSize : NSSize(width: 340, height: 420)
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
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

        var tail = [
            PanelItem(id: "indefinitely", title: "Indefinitely", key: "I") { $0.start(Choice.indefinitely) },
            PanelItem(id: "screen-off", title: "Screen off, Mac awake", key: "Z", symbol: "moon.fill") { $0.sleepDisplayNow() },
        ]
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
@MainActor
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

/// A narrow paper list. Rebuilt when the selection or a toggle changes; the panel itself
/// is key, so these buttons never take the keyboard.
@MainActor
final class KeepAwakePanelRoot: NSView {
    private let model: PanelModel
    private let stack = NSStackView()

    init(model: PanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 340),
        ])
        render()
        track()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Paper.background.setFill()
        bounds.fill()
        Paper.line.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override var isOpaque: Bool { true }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: "Keep Awake")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Paper.ink
        let subtitle = NSTextField(labelWithString: model.keepAwake.session == nil
            ? "Return keeps it awake for 12 hours"
            : model.keepAwake.statusLine)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = Paper.secondary
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 300
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        stack.addArrangedSubview(header)

        for section in model.sections {
            let heading = NSTextField(labelWithString: section.title)
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = Paper.secondary
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 2
            for item in section.items {
                rows.addArrangedSubview(row(item))
            }
            let block = NSStackView(views: [heading, rows])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 4
            stack.addArrangedSubview(block)
        }

        let rule = NSBox()
        rule.boxType = .separator
        rule.widthAnchor.constraint(equalToConstant: 312).isActive = true
        stack.addArrangedSubview(rule)
        stack.addArrangedSubview(optionRow(
            title: model.displayOn ? "Display stays on" : "Display can sleep",
            key: "D",
            on: model.displayOn,
            action: #selector(toggleDisplay)
        ))
        stack.addArrangedSubview(optionRow(
            title: "Only while plugged in",
            key: "P",
            on: model.onlyOnPower,
            action: #selector(togglePower)
        ))
        let hint = NSTextField(labelWithString: "Arrows move · return starts · esc closes")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Paper.secondary
        stack.addArrangedSubview(hint)
        invalidateIntrinsicContentSize()
    }

    private func row(_ item: PanelItem) -> NSButton {
        let selected = model.selection == item.id
        var title = item.title
        if let key = item.key { title += "  \(key)" }
        let button = NSButton(title: title, target: self, action: #selector(pick(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(item.id)
        button.bezelStyle = .recessed
        button.isBordered = selected || item.prominent
        button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        button.contentTintColor = item.id == "stop" ? NSColor(srgbRed: 0.55, green: 0.22, blue: 0.16, alpha: 1) : Paper.ink
        button.alignment = .left
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let icon = item.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            button.image = icon
            button.imagePosition = .imageLeading
        }
        button.widthAnchor.constraint(equalToConstant: 312).isActive = true
        return button
    }

    private func optionRow(title: String, key: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: "\(on ? "●" : "○")  \(title)  \(key)", target: self, action: action)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = Paper.ink
        button.alignment = .left
        button.refusesFirstResponder = true
        button.widthAnchor.constraint(equalToConstant: 312).isActive = true
        return button
    }

    @objc private func pick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let item = model.sections.flatMap(\.items).first(where: { $0.id == id }) else { return }
        model.run(item)
    }

    @objc private func toggleDisplay() {
        model.keepAwake.setKeepsDisplayOn(!model.displayOn)
    }

    @objc private func togglePower() {
        model.keepAwake.setOnlyOnPower(!model.onlyOnPower)
    }

    private func track() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.model.selection
            _ = self.model.displayOn
            _ = self.model.onlyOnPower
            _ = self.model.keepAwake.statusLine
            _ = self.model.keepAwake.session
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.render()
                    self?.track()
                }
            }
        }
    }
}
