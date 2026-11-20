import AppKit

/// AppKit's source list supplies selection, focus, keyboard navigation and vibrancy.
@MainActor
final class SettingsSidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    let table = NSTableView()
    var onSelect: ((SettingsTab) -> Void)?
    var onSearch: ((String) -> Void)?
    private(set) var visibleTabs: [SettingsTab] = SettingsTab.allCases

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.frame = NSRect(x: 0, y: 0, width: 180, height: 620)
        searchField.placeholderString = "Filter settings…"
        searchField.setAccessibilityLabel("Filter settings")
        searchField.font = .systemFont(ofSize: 12)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
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
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Settings categories")
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        background.addSubview(searchField)
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        view = background
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        onSearch?(sender.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearch?(searchField.stringValue)
    }

    func setVisibleTabs(_ tabs: [SettingsTab], selected: SettingsTab?) {
        visibleTabs = tabs
        table.reloadData()
        if let selected { select(selected) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleTabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleTabs.indices.contains(row) else { return nil }
        let tab = visibleTabs[row]
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
        guard visibleTabs.indices.contains(table.selectedRow) else { return }
        onSelect?(visibleTabs[table.selectedRow])
    }

    func select(_ tab: SettingsTab) {
        guard let row = visibleTabs.firstIndex(of: tab), table.selectedRow != row else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}
