import AppKit

/// The scroll view's document. Flipped so a short page sits at the top instead of
/// the bottom. The column itself stays unflipped: flipping a stack reverses it.
@MainActor
final class SettingsPage: NSView {
    override var isFlipped: Bool { true }

    let column: NSStackView

    override init(frame frameRect: NSRect) {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 28, right: 22)
        column.detachesHiddenViews = true
        self.column = column
        super.init(frame: frameRect)
        // Let the stack's contents determine its height. A manually sized stack
        // otherwise contributes required width/height constraints from its initial
        // zero frame, before the first fitting pass can measure the document.
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

}

extension SettingsWindowController {
    func addSection(_ title: String) {
        guard let column else { return }
        if let last = column.arrangedSubviews.last {
            column.setCustomSpacing(20, after: last)
        }
        let header = plainLabel(title, size: 11, weight: .semibold, color: Paper.secondary)
        let rule = SettingsRule()
        pin(rule)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let block = NSStackView(views: [header, rule])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4
        column.addArrangedSubview(block)
    }

    func addToggles(_ tweaks: [Tweak]) {
        guard let column else { return }
        for tweak in tweaks {
            let title = wrappingLabel(tweak.title, size: 13, color: Paper.ink, reserve: 72)
            let detail = wrappingLabel(tweak.detail, size: 11, color: Paper.secondary, reserve: 72)
            let note = wrappingLabel("Waiting for Accessibility permission", size: 11, color: Paper.secondary, reserve: 72)
            note.isHidden = true
            accessNotes[tweak] = note
            let text = NSStackView(views: [title, detail, note])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.detachesHiddenViews = true
            let toggle = NSSwitch()
            toggle.identifier = NSUserInterfaceItemIdentifier(tweak.rawValue)
            toggle.target = self
            toggle.action = #selector(tweakToggled(_:))
            toggle.setContentHuggingPriority(.required, for: .horizontal)
            toggles[tweak] = toggle
            column.addArrangedSubview(labeledRowView(text, trailing: toggle))
        }
    }

    func labeledRow(_ title: String, trailing: NSView, reserve: CGFloat = 72) -> NSView {
        let label = plainLabel(title, size: 13, weight: .regular, color: Paper.ink)
        measured.append((label, reserve))
        return labeledRowView(label, trailing: trailing)
    }

    /// Title on the left, control on the right, across the column. Dynamic boxed
    /// rows use `addRow` to attach before constraining their width.
    func labeledRowView(_ leading: NSView, trailing: NSView, pinToColumn: Bool = true) -> NSView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.distribution = .fill
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        if pinToColumn { pin(row) }
        return row
    }

    /// Attach before activating a constraint that refers to the parent.
    func addRow(_ leading: NSView, trailing: NSView, to box: NSStackView) {
        let row = labeledRowView(leading, trailing: trailing, pinToColumn: false)
        box.addArrangedSubview(row)
        let width = row.widthAnchor.constraint(equalTo: box.widthAnchor)
        width.priority = NSLayoutConstraint.Priority(999)
        width.isActive = true
    }

    /// Column width, updated once the scroll view knows how wide it is.
    func pin(_ view: NSView) {
        let width = view.widthAnchor.constraint(equalToConstant: 456)
        width.priority = NSLayoutConstraint.Priority(999)
        width.isActive = true
        columnConstraints.append(width)
    }

    func plainLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    func wrappingLabel(_ text: String, size: CGFloat, color: NSColor, reserve: CGFloat = 0) -> NSTextField {
        let label = plainLabel(text, size: size, weight: .regular, color: color)
        measured.append((label, reserve))
        return label
    }

    func note(_ text: String) -> NSTextField {
        wrappingLabel(text, size: 11, color: Paper.secondary)
    }

    /// A vertical box whose rows are rebuilt when its model changes.
    func boxed(_ box: NSStackView) {
        guard let column else { return }
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        pin(box)
        column.addArrangedSubview(box)
    }

    func smallLabel(_ text: String, color: NSColor = Paper.secondary) -> NSTextField {
        let label = plainLabel(text, size: 11, weight: .regular, color: color)
        measured.append((label, 0))
        return label
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

/// A 1pt hairline, or a 2pt vertical mark beside the Accessibility note.
@MainActor
final class SettingsRule: NSView {
    var vertical = false {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        vertical
            ? NSSize(width: 2, height: NSView.noIntrinsicMetric)
            : NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        Paper.line.setFill()
        bounds.fill()
    }
}
