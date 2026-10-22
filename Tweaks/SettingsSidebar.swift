import AppKit

/// AppKit's source list supplies selection, focus, keyboard navigation and vibrancy.
@MainActor
final class SettingsSidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var onSelect: ((SettingsTab) -> Void)?

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.frame = NSRect(x: 0, y: 0, width: 180, height: 620)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.addTableColumn(NSTableColumn(identifier: .init("category")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .sourceList
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Settings categories")
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        view = background
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsTab.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tab = SettingsTab.allCases[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: tab.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let tab = SettingsTab(rawValue: table.selectedRow) { onSelect?(tab) }
    }

    func select(_ tab: SettingsTab) {
        guard table.selectedRow != tab.rawValue else { return }
        table.selectRowIndexes(IndexSet(integer: tab.rawValue), byExtendingSelection: false)
    }
}
