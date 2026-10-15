import AppKit

/// One page of the settings window. The switches are the same ones the long scroll had.
enum SettingsTab: Int, CaseIterable {
    case general, files, sleep, windows, network

    var title: String {
        switch self {
        case .general: "General"
        case .files: "Files"
        case .sleep: "Sleep"
        case .windows: "Windows"
        case .network: "Network"
        }
    }
}

extension SettingsWindowController {
    func installPages() -> [SettingsPage] {
        SettingsTab.allCases.map { tab in
            let page = SettingsPage(frame: .zero)
            column = page.column
            switch tab {
            case .general: buildGeneral()
            case .files: buildFiles()
            case .sleep: buildSleep()
            case .windows: buildWindows()
            case .network: buildNetwork()
            }
            return page
        }
    }

    private func buildGeneral() {
        addSection("Shortcuts")
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(shortcut: tweaks.shortcuts.shortcut(for: action)) { [weak self] shortcut in
                self?.tweaks.shortcuts.set(shortcut, for: action)
            }
            recorders[action] = recorder
            column?.addArrangedSubview(labeledRow(action.title, trailing: recorder, reserve: 156))
        }
        column?.addArrangedSubview(note("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. Hyper is ⌃⌥⇧⌘."))

        addSection("Keyboard and sound")
        addToggles([.capsLockNoDelay, .wakeVolumeLimit, .muteIcon, .blockMusicLaunch])

        addSection("Launch")
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        column?.addArrangedSubview(labeledRow("Launch at login", trailing: loginSwitch))
        loginError.font = .systemFont(ofSize: 11)
        loginError.textColor = Paper.secondary
        loginError.lineBreakMode = .byWordWrapping
        loginError.maximumNumberOfLines = 0
        measured.append((loginError, 0))
        column?.addArrangedSubview(loginError)
        column?.addArrangedSubview(note("Closing this window leaves Tweaks running, with no Dock icon. Open it again from Finder or Spotlight."))
        column?.addArrangedSubview(button("Quit Tweaks", #selector(quitTweaks)))
    }

    private func buildFiles() {
        addSection("Downloads and clipboard")
        addToggles([.lowercaseExtensions, .calendarInvites, .dmgInstaller, .unzipDownloads, .cleanCopiedLinks])

        addSection("Finder")
        column?.addArrangedSubview(note("Copy Path shortens NAS, Box and Google Drive roots. Copy Original Path and Inspect Media are on the same menu. Turn the extension on under Finder Extensions."))
        finderLabel.font = .systemFont(ofSize: 12)
        finderLabel.textColor = Paper.secondary
        finderLabel.lineBreakMode = .byTruncatingTail
        let finderButton = button("Finder Extensions…", #selector(showFinderExtensions))
        column?.addArrangedSubview(labeledRowView(finderLabel, trailing: finderButton))
    }

    private func buildSleep() {
        addSection("Sleep")
        addToggles([.keepAwakeHotKey])
        countdownSwitch.target = self
        countdownSwitch.action = #selector(countdownChanged(_:))
        column?.addArrangedSubview(labeledRow("Show time left next to the cup", trailing: countdownSwitch))
        sessionLabel.font = .systemFont(ofSize: 12)
        sessionLabel.textColor = Paper.secondary
        sessionLabel.lineBreakMode = .byTruncatingTail
        sessionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stop = button("Stop", #selector(stopKeepAwake))
        sessionRow.orientation = .horizontal
        sessionRow.distribution = .fill
        sessionRow.spacing = 8
        sessionRow.addArrangedSubview(sessionLabel)
        sessionRow.addArrangedSubview(stop)
        pin(sessionRow)
        column?.addArrangedSubview(sessionRow)
        addToggles([.ejectBeforeSleep, .awakeWhileRendering])
        renderLabel.font = .systemFont(ofSize: 12)
        renderLabel.textColor = Paper.secondary
        renderLabel.lineBreakMode = .byWordWrapping
        renderLabel.maximumNumberOfLines = 0
        measured.append((renderLabel, 0))
        column?.addArrangedSubview(renderLabel)
    }

    private func buildWindows() {
        addSection("Windows and notifications")
        addToggles([.clearNotificationsHotKey, .dismissShortcutNotifications, .greenButtonFills])
        column?.addArrangedSubview(button("Clear notifications now", #selector(clearNotifications)))

        addSection("Quit when the last window closes")
        addToggles([.quitOnLastWindow])
        appsBox.orientation = .vertical
        appsBox.alignment = .leading
        appsBox.spacing = 4
        pin(appsBox)
        column?.addArrangedSubview(appsBox)
        column?.addArrangedSubview(button("Add App…", #selector(addQuitApp)))
    }

    private func buildNetwork() {
        addSection("Network")
        addToggles([.unmountSharesBeforeSleep, .autoConnectShares])
        sharesBox.orientation = .vertical
        sharesBox.alignment = .leading
        sharesBox.spacing = 4
        pin(sharesBox)
        column?.addArrangedSubview(sharesBox)
        shareField.placeholderString = "smb://server/share"
        shareField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shareField.textColor = Paper.ink
        shareField.target = self
        shareField.action = #selector(addShare)
        shareField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shareField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addShareButton.title = "Add"
        addShareButton.bezelStyle = .rounded
        addShareButton.target = self
        addShareButton.action = #selector(addShare)
        addShareButton.setContentHuggingPriority(.required, for: .horizontal)
        let addRow = NSStackView(views: [shareField, addShareButton])
        addRow.orientation = .horizontal
        addRow.distribution = .fill
        addRow.spacing = 8
        pin(addRow)
        column?.addArrangedSubview(addRow)
    }
}
