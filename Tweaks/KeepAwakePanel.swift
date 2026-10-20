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

        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        // Opaque on purpose. A clear panel with a shadow keeps the window server redrawing
        // the shadow for as long as the panel object exists.
        panel.isOpaque = true
        panel.backgroundColor = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        let root = KeepAwakePanelRoot(model: model)
        panel.contentView = root
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize.width > 1 ? root.fittingSize : NSSize(width: 620, height: 420)
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
        panel?.contentView = nil
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
    var detail: String?
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
        selection = "away"
        sections = buildSections()
    }

    private var allItems: [PanelItem] { sections.flatMap(\.items) }

    private func buildSections() -> [PanelSection] {
        let session = keepAwake.session
        var items = [
            PanelItem(id: "away", title: "Away · dim, never lock", key: "A", symbol: "moon.circle",
                      prominent: session?.dimsWhenIdle != true,
                      detail: "Stays awake and never locks, so you and agents can always get in. The screen dims after 2 idle minutes and wakes on any input. Stays unlocked while you're away.") { $0.startAway() },
            PanelItem(id: "dim-now", title: "Dim now", key: "Z", symbol: "moon.fill",
                      detail: "Away mode, with the screen dimmed right now.") { $0.sleepDisplayNow() },
            PanelItem(id: "screen-on", title: "Screen stays on", key: "O", symbol: "sun.max",
                      detail: "Screen never dims or sleeps. For renders or anything you want to watch.") { $0.startScreenOn() },
        ]
        if session != nil {
            items.append(PanelItem(id: "stop", title: "Stop", key: "S", symbol: "stop.circle") { $0.stop(reason: "Stopped.") })
        }
        return [PanelSection(id: "mode", title: "Keep the Mac awake", items: items)]
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
        return false
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

/// The dark chip panel. Plain AppKit (no SwiftUI, to keep idle memory low). Rebuilt when
/// the selection or a toggle changes; the panel itself is key, so chips never take the keyboard.
@MainActor
final class KeepAwakePanelRoot: NSView {
    static let width: CGFloat = 620
    static let inset: CGFloat = 18
    private static let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
    private static let background = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)

    private let model: PanelModel
    private var contentHeight: CGFloat = 200

    override var isFlipped: Bool { true }

    init(model: PanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        appearance = NSAppearance(named: .darkAqua)
        render()
        track()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: contentHeight) }
    override var fittingSize: NSSize { NSSize(width: Self.width, height: contentHeight) }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.sizeToFit()
        return field
    }

    private func render() {
        subviews.forEach { $0.removeFromSuperview() }
        let inset = Self.inset
        let maxX = Self.width - inset
        var y = inset

        // Header
        let active = model.keepAwake.session != nil
        let cup = NSImageView(image: NSImage(systemSymbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold)) ?? NSImage())
        cup.contentTintColor = active ? Self.orange : .secondaryLabelColor
        cup.frame = NSRect(x: inset, y: y + 4, width: 24, height: 24)
        addSubview(cup)
        let title = label("Keep Awake", size: 15, weight: .semibold, color: .labelColor)
        title.setFrameOrigin(NSPoint(x: inset + 34, y: y))
        addSubview(title)
        let subtitle = label(active ? model.keepAwake.statusLine : "Return: Away. Awake and unlocked; the screen dims when idle",
                             size: 12, color: .secondaryLabelColor)
        subtitle.setFrameOrigin(NSPoint(x: inset + 34, y: y + 18))
        addSubview(subtitle)
        y += 32 + 14

        // Sections of wrapping chips
        for section in model.sections {
            let heading = label(section.title.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
            heading.setFrameOrigin(NSPoint(x: inset, y: y))
            addSubview(heading)
            y += heading.frame.height + 6
            var x = inset
            var rowHeight: CGFloat = 0
            for item in section.items {
                let chip = ChipView(title: item.title, key: item.key, symbol: item.symbol, icon: item.icon,
                                    selected: model.selection == item.id, prominent: item.prominent,
                                    destructive: item.id == "stop")
                chip.onClick = { [weak self] in self?.model.run(item) }
                chip.onHover = { [weak self] in self?.model.selection = item.id }
                chip.toolTip = item.detail
                chip.setAccessibilityHelp(item.detail)
                let size = chip.frame.size
                if x > inset, x + size.width > maxX { x = inset; y += rowHeight + 6; rowHeight = 0 }
                chip.setFrameOrigin(NSPoint(x: x, y: y))
                addSubview(chip)
                x += size.width + 6
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + 14
        }

        // Always reserve two lines so keyboard selection does not resize the panel.
        let detailText = model.sections.flatMap(\.items).first { $0.id == model.selection }?.detail
        let detail = NSTextField(wrappingLabelWithString: detailText ?? "Both modes run until you stop them. Renders also keep the Mac awake on their own.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: inset, y: y, width: Self.width - inset * 2, height: 42)
        addSubview(detail)
        y += 48

        let height: CGFloat = 16
        let hint = label("←→ move · ⏎ start · esc close", size: 10, color: .tertiaryLabelColor)
        hint.setFrameOrigin(NSPoint(x: inset, y: y))
        addSubview(hint)
        y += height + inset

        contentHeight = y
        setFrameSize(NSSize(width: Self.width, height: y))
        invalidateIntrinsicContentSize()
        needsDisplay = true
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
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { return }
                    self.render()
                    self.track()
                }
            }
        }
    }
}

/// A rounded chip: optional icon or symbol, title, and a small key cap.
@MainActor
private final class ChipView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private let title: String
    private let key: String?
    private let image: NSImage?
    private let selected: Bool
    private let prominent: Bool
    private let destructive: Bool
    private let checked: Bool

    override var isFlipped: Bool { true }

    init(title: String, key: String?, symbol: String?, icon: NSImage?, selected: Bool, prominent: Bool,
         destructive: Bool, checked: Bool = false) {
        self.title = title
        self.key = key
        self.selected = selected
        self.prominent = prominent
        self.destructive = destructive
        self.checked = checked
        if let icon = icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            image = icon
        } else if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        } else {
            image = nil
        }
        super.init(frame: .zero)
        var width: CGFloat = 20 + titleSize.width
        if image != nil { width += 22 }
        if let key { width += 6 + keySize(key).width + 8 }
        setFrameSize(NSSize(width: ceil(width), height: 30))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
         .foregroundColor: destructive ? NSColor.systemRed : NSColor.labelColor]
    }
    private var titleSize: NSSize { (title as NSString).size(withAttributes: titleAttributes) }
    private let keyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
    private func keySize(_ key: String) -> NSSize {
        let size = (key as NSString).size(withAttributes: keyAttributes)
        return NSSize(width: size.width + 8, height: size.height + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (selected ? orange.withAlphaComponent(0.3) : NSColor.white.withAlphaComponent(0.06)).setFill()
        shape.fill()
        (selected ? orange : (prominent ? orange.withAlphaComponent(0.5) : NSColor.white.withAlphaComponent(0.06))).setStroke()
        shape.stroke()

        var x: CGFloat = 10
        if let image {
            let side = image.size
            let rect = NSRect(x: x, y: (bounds.height - side.height) / 2, width: side.width, height: side.height)
            if image.isTemplate {
                let tint = checked ? orange : NSColor.secondaryLabelColor
                let tinted = NSImage(size: side, flipped: false) { r in
                    image.draw(in: r); tint.set(); r.fill(using: .sourceAtop); return true }
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            x += 22
        }
        let size = titleSize
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: titleAttributes)
        if let key {
            let kSize = keySize(key)
            let cap = NSRect(x: x + size.width + 6, y: (bounds.height - kSize.height) / 2, width: kSize.width, height: kSize.height)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 3, yRadius: 3).fill()
            (key as NSString).draw(at: NSPoint(x: cap.minX + 4, y: cap.minY + 1), withAttributes: keyAttributes)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
