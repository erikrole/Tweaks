import AppKit

/// Warm paper and ink, shared by the settings window, the Keep Awake panel and the HUD.
/// Main-actor isolated: `NSColor` is a class, so a plain static would be shared mutable state.
@MainActor
enum Paper {
    static let background = NSColor(srgbRed: 0.945, green: 0.933, blue: 0.906, alpha: 1)
    static let ink = NSColor(srgbRed: 0.18, green: 0.16, blue: 0.13, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.30, alpha: 1)
    static let line = NSColor(srgbRed: 0.74, green: 0.68, blue: 0.60, alpha: 1)
}

/// A small dark pill near the bottom of the screen you're on. It never takes focus
/// or catches clicks, and it is thrown away when its time is up so it doesn't sit in memory.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    /// Bumped on every show, so a hide already queued cannot dismiss the next slip.
    private static var generation = 0

    static func show(_ text: String, symbol: String, duration: TimeInterval = 1.6) {
        generation += 1
        let token = generation
        let existing = panel
        let panel = existing ?? makePanel()
        self.panel = panel
        let view = HUDSlip(text: text, symbol: symbol)
        panel.contentView = view
        view.layoutSubtreeIfNeeded()
        let fitted = view.fittingSize
        let size = NSSize(width: min(max(fitted.width, 80), 420), height: max(fitted.height, 28))
        // NSEvent stays on this actor. Only the point is used, and it is not sent anywhere.
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Shown and removed directly. Fading it installed a display link, and a clear
        // panel with an opaque slip was keeping that link after the slip was gone.
        hideWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { HUD.dismiss(token) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func dismiss(_ token: Int) {
        guard generation == token else { return }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hideWork = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Clear for the rounded pill, and no shadow: a clear panel with a shadow keeps the
        // window server redrawing it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

@MainActor
private final class HUDSlip: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, symbol: String) {
        super.init(frame: .zero)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            icon.contentTintColor = HUDSlip.orange
            icon.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(icon)
        }
        label.stringValue = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    static let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)

    /// A dark capsule with a hairline, matching the Keep Awake panel. Drawn, not layer-backed.
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 0.96).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        pill.lineWidth = 1
        pill.stroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
