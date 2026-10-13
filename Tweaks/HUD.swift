import AppKit

/// Warm paper and ink, shared by the settings window, the Keep Awake panel and the HUD.
enum Paper {
    static let background = NSColor(srgbRed: 0.945, green: 0.933, blue: 0.906, alpha: 1)
    static let ink = NSColor(srgbRed: 0.18, green: 0.16, blue: 0.13, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.30, alpha: 1)
    static let line = NSColor(srgbRed: 0.74, green: 0.68, blue: 0.60, alpha: 1)
    static let wash = NSColor(srgbRed: 0.18, green: 0.15, blue: 0.12, alpha: 0.08)
}

/// A small slip of paper near the bottom of the screen you're on. It never takes focus
/// or catches clicks, and it is thrown away after it fades so it doesn't sit in memory.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String, duration: TimeInterval = 1.6) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let view = HUDSlip(text: text, symbol: symbol)
        panel.contentView = view
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        panel.orderOut(nil)
                        panel.contentView = nil
                        if self.panel === panel { self.panel = nil }
                    }
                })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
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
        wantsLayer = true
        layer?.backgroundColor = Paper.background.cgColor
        layer?.cornerRadius = 2
        layer?.borderWidth = 1
        layer?.borderColor = Paper.line.cgColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            icon.contentTintColor = Paper.ink
            icon.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(icon)
        }
        label.stringValue = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = Paper.ink
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
