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
        // Clear for the rounded corners. The panel is thrown away on close, so the shadow
        // redraw a clear panel costs only lasts while it's on screen.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        let root = KeepAwakePanelRoot(model: model)
        panel.contentView = root
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize.width > 1 ? root.fittingSize : NSSize(width: 380, height: 200)
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
        selection = keepAwake.session?.dimsWhenIdle == false ? "screen-on" : "away"
        sections = buildSections()
    }

    private var allItems: [PanelItem] { sections.flatMap(\.items) }

    private func buildSections() -> [PanelSection] {
        var items = [
            PanelItem(id: "away", title: "Away", key: "A", symbol: "moon.fill",
                      detail: "Awake and unlocked. Screen dims when idle.") { $0.startAway() },
            PanelItem(id: "screen-on", title: "Screen on", key: "O", symbol: "sun.max.fill",
                      detail: "Never dims or sleeps. For renders.") { $0.startScreenOn() },
        ]
        if keepAwake.session != nil {
            items.append(PanelItem(id: "stop", title: "Stop", key: "S") { $0.stop(reason: "Stopped.") })
        }
        return [PanelSection(id: "mode", title: "Mode", items: items)]
    }

    /// The card for the running mode, if one is.
    var activeID: String? {
        guard let session = keepAwake.session else { return nil }
        if session.dimsWhenIdle { return "away" }
        return session.keepsDisplayOn ? "screen-on" : nil
    }

    func dimNow() {
        keepAwake.sleepDisplayNow()
        onDone?()
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
        if key == "z" { dimNow(); return true }
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

/// Two mode cards on a dark rounded panel. Plain AppKit (no SwiftUI, to keep idle memory
/// low). Rebuilt when the selection or session changes; the panel itself is key, so the
/// cards never take the keyboard.
@MainActor
final class KeepAwakePanelRoot: NSView {
    static let width: CGFloat = 380
    static let inset: CGFloat = 16
    static let radius: CGFloat = 14
    static let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
    static let background = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)

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
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        Self.background.setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = 1
        shape.stroke()
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
        var y = inset

        let title = label("Keep Awake", size: 13, weight: .semibold, color: .labelColor)
        title.setFrameOrigin(NSPoint(x: inset, y: y))
        addSubview(title)
        let status = label(model.keepAwake.session == nil ? "Off" : model.keepAwake.statusLine, size: 12,
                           color: model.keepAwake.session == nil ? .tertiaryLabelColor : Self.orange)
        status.setFrameOrigin(NSPoint(x: Self.width - inset - status.frame.width, y: y + 1))
        addSubview(status)
        y += title.frame.height + 12

        let modes = model.sections.flatMap(\.items).filter { $0.id != "stop" }
        let gap: CGFloat = 10
        let cardWidth = (Self.width - inset * 2 - gap) / 2
        for (index, item) in modes.enumerated() {
            let card = ModeCard(item: item, selected: model.selection == item.id, active: model.activeID == item.id)
            card.frame = NSRect(x: inset + CGFloat(index) * (cardWidth + gap), y: y, width: cardWidth, height: ModeCard.height)
            card.onClick = { [weak self] option in
                guard let self else { return }
                if option, item.id == "away" { self.model.dimNow() } else { self.model.run(item) }
            }
            card.onHover = { [weak self] in self?.model.selection = item.id }
            addSubview(card)
        }
        y += ModeCard.height + 12

        let hint = label("⌥-click Away or press Z to dim now · esc", size: 10, color: .tertiaryLabelColor)
        hint.setFrameOrigin(NSPoint(x: inset, y: y + 3))
        addSubview(hint)
        if let stop = model.sections.flatMap(\.items).first(where: { $0.id == "stop" }) {
            let button = TextLink(title: "Stop  S", color: .systemRed) { [weak self] in self?.model.run(stop) }
            button.setFrameOrigin(NSPoint(x: Self.width - inset - button.frame.width, y: y))
            addSubview(button)
            y += max(button.frame.height, hint.frame.height + 3)
        } else {
            y += hint.frame.height + 3
        }
        y += inset

        contentHeight = y
        setFrameSize(NSSize(width: Self.width, height: y))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func track() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.model.selection
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

/// A mode card: a large symbol, the mode name with its key, and one line on what it does.
/// Orange fill when selected, orange ring and an "On" tag when it's the running mode.
@MainActor
private final class ModeCard: NSView {
    static let height: CGFloat = 104
    var onClick: ((Bool) -> Void)?
    var onHover: (() -> Void)?
    private let item: PanelItem
    private let selected: Bool
    private let active: Bool

    override var isFlipped: Bool { true }

    init(item: PanelItem, selected: Bool, active: Bool) {
        self.item = item
        self.selected = selected
        self.active = active
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityHelp(item.detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let orange = KeepAwakePanelRoot.orange
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (selected ? orange.withAlphaComponent(0.22) : NSColor.white.withAlphaComponent(0.05)).setFill()
        shape.fill()
        (active || selected ? orange : NSColor.white.withAlphaComponent(0.08)).setStroke()
        shape.lineWidth = active ? 1.5 : 1
        shape.stroke()

        let pad: CGFloat = 12
        if let symbol = item.symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 20, weight: .semibold)) {
            let size = image.size
            let tint = active || selected ? orange : NSColor.secondaryLabelColor
            let tinted = NSImage(size: size, flipped: false) { r in
                image.draw(in: r); tint.set(); r.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: pad, y: pad, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if active {
            let tag: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: orange]
            let tagSize = ("ON" as NSString).size(withAttributes: tag)
            ("ON" as NSString).draw(at: NSPoint(x: bounds.width - pad - tagSize.width, y: pad + 2), withAttributes: tag)
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                          .foregroundColor: NSColor.labelColor]
        let titleSize = (item.title as NSString).size(withAttributes: titleAttrs)
        let titleY: CGFloat = 46
        (item.title as NSString).draw(at: NSPoint(x: pad, y: titleY), withAttributes: titleAttrs)
        if let key = item.key {
            let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                            .foregroundColor: NSColor.secondaryLabelColor]
            let kSize = (key as NSString).size(withAttributes: keyAttrs)
            let cap = NSRect(x: pad + titleSize.width + 6, y: titleY + (titleSize.height - kSize.height - 2) / 2,
                             width: kSize.width + 8, height: kSize.height + 2)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 3, yRadius: 3).fill()
            (key as NSString).draw(at: NSPoint(x: cap.minX + 4, y: cap.minY + 1), withAttributes: keyAttrs)
        }
        if let detail = item.detail {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let detailAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                               .foregroundColor: NSColor.secondaryLabelColor,
                                                               .paragraphStyle: style]
            (detail as NSString).draw(in: NSRect(x: pad, y: titleY + titleSize.height + 2, width: bounds.width - pad * 2,
                                                 height: bounds.height - titleY - titleSize.height - pad),
                                      withAttributes: detailAttrs)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?(event.modifierFlags.contains(.option)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small borderless text button.
@MainActor
private final class TextLink: NSView {
    private let title: String
    private let color: NSColor
    private let action: () -> Void
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
    }

    override var isFlipped: Bool { true }

    init(title: String, color: NSColor, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
        super.init(frame: .zero)
        let size = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        setFrameSize(NSSize(width: ceil(size.width) + 4, height: ceil(size.height) + 2))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        (title as NSString).draw(at: NSPoint(x: 2, y: 1), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { action() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
