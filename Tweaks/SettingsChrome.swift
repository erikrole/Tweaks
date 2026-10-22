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
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 8, left: 28, bottom: 28, right: 28)
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
    var content: NSStackView? { sectionColumn ?? column }

    func addSection(_ title: String) {
        guard let column else { return }
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(24, after: last) }
        let header = plainLabel(title, size: 13, weight: .semibold, color: .labelColor)
        column.addArrangedSubview(header)
        column.setCustomSpacing(8, after: header)
        let group = SettingsGroup()
        column.addArrangedSubview(group)
        pin(group, inset: 0)
        sectionColumn = group.column
    }

    func addToggles(_ tweaks: [Tweak]) {
        guard let content else { return }
        for tweak in tweaks {
            let toggle = NSButton(checkboxWithTitle: tweak.title, target: self, action: #selector(tweakToggled(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(tweak.rawValue)
            toggle.font = .systemFont(ofSize: 13)
            toggle.setAccessibilityHelp(tweak.detail)
            toggles[tweak] = toggle
            let detail = wrappingLabel(tweak.detail, size: 11, color: .secondaryLabelColor, reserve: 20)
            let note = wrappingLabel("Waiting for Accessibility permission", size: 11, color: .systemOrange, reserve: 20)
            note.isHidden = true
            accessNotes[tweak] = note
            let help = NSStackView(views: [detail, note])
            help.orientation = .vertical
            help.alignment = .leading
            help.spacing = 3
            help.detachesHiddenViews = true
            help.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            let row = NSStackView(views: [toggle, help])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            content.addArrangedSubview(row)
            pin(row)
        }
    }

    func labeledRow(_ title: String, trailing: NSView, reserve: CGFloat = 72) -> NSView {
        let label = plainLabel(title, size: 13, weight: .regular, color: .labelColor)
        measured.append((label, reserve + (sectionColumn == nil ? 0 : 24)))
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
    func pin(_ view: NSView, inset: CGFloat? = nil) {
        let width = view.widthAnchor.constraint(equalToConstant: 456)
        width.priority = NSLayoutConstraint.Priority(999)
        width.isActive = true
        columnConstraints.append((width, inset ?? (sectionColumn == nil ? 0 : 24)))
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
        measured.append((label, reserve + (sectionColumn == nil ? 0 : 24)))
        return label
    }

    func note(_ text: String) -> NSTextField {
        wrappingLabel(text, size: 11, color: .secondaryLabelColor)
    }

    /// A vertical box whose rows are rebuilt when its model changes.
    func boxed(_ box: NSStackView) {
        guard let content else { return }
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        pin(box)
        content.addArrangedSubview(box)
    }

    func smallLabel(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = plainLabel(text, size: 11, weight: .regular, color: color)
        measured.append((label, 24))
        return label
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

/// Standard AppKit box with semantic system colors; content remains ordinary controls.
@MainActor
final class SettingsGroup: NSView {
    let column = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let background = NSBox()
        background.boxType = .custom
        background.titlePosition = .noTitle
        background.borderType = .lineBorder
        background.borderColor = .separatorColor
        background.borderWidth = 0.5
        background.cornerRadius = 8
        background.fillColor = .controlBackgroundColor
        background.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        addSubview(column)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
