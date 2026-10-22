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
            let page = SettingsPage(frame: NSRect(x: 0, y: 0, width: 500, height: 1))
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
        addToggles([.capsLockNoDelay, .muteIcon, .blockMusicLaunch])
        addSection("Volume limits")
        addToggles([.wakeVolumeLimit])
        wakeLimitSlider.isContinuous = false
        wakeLimitSlider.setAccessibilityLabel("Default maximum after waking")
        wakeLimitSlider.target = self
        wakeLimitSlider.action = #selector(wakeMaximumChanged(_:))
        wakeLimitSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        column?.addArrangedSubview(labeledRowView(wakeLimitLabel, trailing: wakeLimitSlider))
        addToggles([.deviceVolumeLimits])
        column?.addArrangedSubview(note("The default applies after waking. Device overrides apply on output changes and volume increases when enabled. If both apply, the lower maximum wins."))
        boxed(volumeBox)
        tweaks.volumeLimits.refreshDevices()

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
        addSection("Automatic actions")
        pauseStatus.lineBreakMode = .byWordWrapping
        pauseStatus.maximumNumberOfLines = 0
        measured.append((pauseStatus, 0))
        column?.addArrangedSubview(pauseStatus)
        pauseButton.title = "Pause for 30 Minutes"
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(toggleAutomationPause)
        column?.addArrangedSubview(pauseButton)
        column?.addArrangedSubview(note("Pauses Downloads actions, disk-image offers, and automatic link cleaning without changing your switches. Files received during the pause stay untouched after resuming. Manual actions remain available."))

        addSection("Downloads and clipboard")
        addToggles([.lowercaseExtensions, .calendarInvites, .dmgInstaller, .unzipDownloads, .cleanCopiedLinks, .duplicateDownloads])
        boxed(duplicateBox)

        addSection("Copied links")
        let linkButtons = NSStackView(views: [button("Clean Link Now", #selector(cleanLinkNow)), restoreLinkButton])
        linkButtons.orientation = .horizontal
        linkButtons.spacing = 8
        restoreLinkButton.title = "Restore Original"
        restoreLinkButton.bezelStyle = .rounded
        restoreLinkButton.target = self
        restoreLinkButton.action = #selector(restoreOriginalLink)
        column?.addArrangedSubview(linkButtons)
        linkStatus.lineBreakMode = .byWordWrapping
        linkStatus.maximumNumberOfLines = 0
        measured.append((linkStatus, 0))
        column?.addArrangedSubview(linkStatus)
        excludedHostsField.placeholderString = "example.com, another.example"
        excludedHostsField.setAccessibilityLabel("Sites to leave unchanged")
        excludedHostsField.target = self
        excludedHostsField.action = #selector(saveLinkExclusions)
        pin(excludedHostsField)
        column?.addArrangedSubview(plainLabel("Sites to leave unchanged (including subdomains)", size: 12, weight: .regular, color: Paper.ink))
        column?.addArrangedSubview(excludedHostsField)
        column?.addArrangedSubview(button("Save Site Exclusions", #selector(saveLinkExclusions)))
        column?.addArrangedSubview(note("Clean Link Now works even when automatic cleaning is off or paused. A global shortcut can be assigned under General. Original links stay in memory only; copying anything else prevents restoration over newer clipboard contents."))

        addSection("Finder")
        column?.addArrangedSubview(button("Quick Image Actions…", #selector(chooseImages)))
        column?.addArrangedSubview(note("Convert or resize selected images and optionally remove metadata. Originals are kept. Also available from Finder's right-click menu."))
        column?.addArrangedSubview(note("Copy Path shortens NAS, Box and Google Drive roots. Copy Original Path and Inspect Media are on the same menu. Turn the extension on under Finder Extensions."))
        finderLabel.font = .systemFont(ofSize: 12)
        finderLabel.textColor = Paper.secondary
        finderLabel.lineBreakMode = .byTruncatingTail
        let finderButton = button("Finder Extensions…", #selector(showFinderExtensions))
        column?.addArrangedSubview(labeledRowView(finderLabel, trailing: finderButton))

        addSection("Recent actions")
        column?.addArrangedSubview(note("The latest 100 file, link, volume and pause actions from this session. History is cleared when Tweaks quits and is never saved to disk."))
        boxed(recentActionsBox)
        column?.addArrangedSubview(button("Clear Recent Actions", #selector(clearRecentActions)))
    }

    private func buildSleep() {
        addSection("Sleep")
        addToggles([.keepAwakeHotKey])
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
        addToggles([.ejectBeforeSleep, .safeEjectHotKey])
        ejectButton.title = "Eject Idle External Drives"
        ejectButton.bezelStyle = .rounded
        ejectButton.font = .systemFont(ofSize: 12)
        ejectButton.target = self
        ejectButton.action = #selector(ejectIdleDrives)
        ejectButton.setContentHuggingPriority(.required, for: .horizontal)
        column?.addArrangedSubview(ejectButton)
        ejectResults.font = .systemFont(ofSize: 11)
        ejectResults.textColor = Paper.secondary
        ejectResults.lineBreakMode = .byWordWrapping
        ejectResults.maximumNumberOfLines = 0
        ejectResults.isSelectable = true
        measured.append((ejectResults, 0))
        column?.addArrangedSubview(ejectResults)
        addToggles([.awakeWhileRendering])
        renderLabel.font = .systemFont(ofSize: 12)
        renderLabel.textColor = Paper.secondary
        renderLabel.lineBreakMode = .byWordWrapping
        renderLabel.maximumNumberOfLines = 0
        measured.append((renderLabel, 0))
        column?.addArrangedSubview(renderLabel)
    }

    private func buildWindows() {
        addSection("Windows and notifications")
        addToggles([.clearNotificationsHotKey, .dismissShortcutNotifications, .greenButtonFills, .windowLayouts])
        layoutButtons = [button("Save This Layout", #selector(saveLayout)),
                         button("Restore Layout", #selector(restoreLayout)),
                         button("Forget Layout", #selector(forgetLayout))]
        layoutRow.setViews(layoutButtons, in: .leading)
        layoutRow.orientation = .horizontal
        layoutRow.spacing = 8
        column?.addArrangedSubview(layoutRow)
        layoutStatus.font = .systemFont(ofSize: 11)
        layoutStatus.textColor = Paper.secondary
        layoutStatus.lineBreakMode = .byWordWrapping
        layoutStatus.maximumNumberOfLines = 0
        measured.append((layoutStatus, 0))
        column?.addArrangedSubview(layoutStatus)
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
        addToggles([.preferEthernetForVPN, .vpnReconnectReminder, .unmountSharesBeforeSleep, .autoConnectShares])
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
