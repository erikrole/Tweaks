import AppKit

/// Flat settings categories keep tools and preferences easy to find.
enum SettingsTab: Int, CaseIterable {
    case general, audio, files, links, sleep, windows, network, shortcuts, activity

    var title: String {
        switch self {
        case .general: "General"
        case .audio: "Audio"
        case .files: "Files & Finder"
        case .links: "Copied Links"
        case .sleep: "Keep Awake"
        case .windows: "Windows"
        case .network: "Network"
        case .shortcuts: "Shortcuts"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .audio: "speaker.wave.2"
        case .files: "folder"
        case .links: "link"
        case .sleep: "moon"
        case .windows: "macwindow.on.rectangle"
        case .network: "network"
        case .shortcuts: "keyboard"
        case .activity: "clock.arrow.circlepath"
        }
    }

    var summary: String {
        switch self {
        case .general: "Startup and keyboard preferences."
        case .audio: "Volume limits, mute status, and the play key."
        case .files: "Downloads, duplicate review, and Finder tools."
        case .links: "Clean tracking from copied links and manage site exclusions."
        case .sleep: "Keep your Mac awake and manage connected drives."
        case .windows: "Window behavior, layouts, and notifications."
        case .network: "Work shares and dock-aware VPN preferences."
        case .shortcuts: "Choose global keyboard shortcuts for Tweaks actions."
        case .activity: "Pause automatic actions and review this session’s history."
        }
    }
}

extension SettingsWindowController {
    func installPages() -> [SettingsPage] {
        SettingsTab.allCases.map { tab in
            let page = SettingsPage(frame: NSRect(x: 0, y: 0, width: 640, height: 1))
            column = page.column
            sectionColumn = nil
            switch tab {
            case .general: buildGeneral()
            case .audio: buildAudio()
            case .links: buildLinks()
            case .shortcuts: buildShortcuts()
            case .activity: buildActivity()
            case .files: buildFiles()
            case .sleep: buildSleep()
            case .windows: buildWindows()
            case .network: buildNetwork()
            }
            return page
        }
    }

    private func buildGeneral() {
        addSection("Keyboard")
        addToggles([.capsLockNoDelay])
        addSection("Launch")
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        content?.addArrangedSubview(labeledRow("Launch at login", trailing: loginSwitch))
        loginError.font = .systemFont(ofSize: 11)
        loginError.textColor = .secondaryLabelColor
        loginError.lineBreakMode = .byWordWrapping
        loginError.maximumNumberOfLines = 0
        measured.append((loginError, 24))
        content?.addArrangedSubview(loginError)
        content?.addArrangedSubview(note("Closing this window leaves Tweaks running, with no Dock icon. Open it again from Finder or Spotlight."))
        content?.addArrangedSubview(button("Quit Tweaks", #selector(quitTweaks)))
    }

    private func buildAudio() {
        addSection("Keyboard and sound")
        addToggles([.muteIcon, .blockMusicLaunch])
        addSection("Volume limits")
        addToggles([.wakeVolumeLimit])
        wakeLimitSlider.isContinuous = false
        wakeLimitSlider.setAccessibilityLabel("Default maximum after waking")
        wakeLimitSlider.target = self
        wakeLimitSlider.action = #selector(wakeMaximumChanged(_:))
        wakeLimitSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        content?.addArrangedSubview(labeledRowView(wakeLimitLabel, trailing: wakeLimitSlider))
        addToggles([.deviceVolumeLimits])
        content?.addArrangedSubview(note("The default applies after waking. Device overrides apply on output changes and volume increases when enabled. If both apply, the lower maximum wins."))
        boxed(volumeBox)
        tweaks.volumeLimits.refreshDevices()

    }

    private func buildShortcuts() {
        addSection("Shortcuts")
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(shortcut: tweaks.shortcuts.shortcut(for: action)) { [weak self] shortcut in
                self?.tweaks.shortcuts.set(shortcut, for: action)
            }
            recorders[action] = recorder
            content?.addArrangedSubview(labeledRow(action.title, trailing: recorder, reserve: 156))
        }
        content?.addArrangedSubview(note("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. Hyper is ⌃⌥⇧⌘."))

    }

    private func buildFiles() {
        addSection("Downloads")
        addToggles([.lowercaseExtensions, .calendarInvites, .dmgInstaller, .unzipDownloads, .duplicateDownloads])
        boxed(duplicateBox)

        addSection("Finder")
        content?.addArrangedSubview(button("Quick Image Actions…", #selector(chooseImages)))
        content?.addArrangedSubview(note("Convert or resize selected images and optionally remove metadata. Originals are kept. Also available from Finder's right-click menu."))
        content?.addArrangedSubview(note("Copy Path shortens NAS, Box and Google Drive roots. Copy Original Path and Inspect Media are on the same menu. Turn the extension on under Finder Extensions."))
        finderLabel.font = .systemFont(ofSize: 12)
        finderLabel.textColor = .secondaryLabelColor
        finderLabel.lineBreakMode = .byTruncatingTail
        let finderButton = button("Finder Extensions…", #selector(showFinderExtensions))
        content?.addArrangedSubview(labeledRowView(finderLabel, trailing: finderButton))

    }

    private func buildLinks() {
        addSection("Link cleaning")
        addToggles([.cleanCopiedLinks])
        let linkButtons = NSStackView(views: [button("Clean Link Now", #selector(cleanLinkNow)), restoreLinkButton])
        linkButtons.orientation = .horizontal
        linkButtons.spacing = 8
        restoreLinkButton.title = "Restore Original"
        restoreLinkButton.bezelStyle = .rounded
        restoreLinkButton.target = self
        restoreLinkButton.action = #selector(restoreOriginalLink)
        content?.addArrangedSubview(linkButtons)
        linkStatus.lineBreakMode = .byWordWrapping
        linkStatus.maximumNumberOfLines = 0
        measured.append((linkStatus, 24))
        content?.addArrangedSubview(linkStatus)
        excludedHostsField.placeholderString = "example.com, another.example"
        excludedHostsField.setAccessibilityLabel("Sites to leave unchanged")
        excludedHostsField.target = self
        excludedHostsField.action = #selector(saveLinkExclusions)
        pin(excludedHostsField)
        content?.addArrangedSubview(plainLabel("Sites to leave unchanged (including subdomains)", size: 12, weight: .regular, color: .labelColor))
        content?.addArrangedSubview(excludedHostsField)
        content?.addArrangedSubview(button("Save Site Exclusions", #selector(saveLinkExclusions)))
        content?.addArrangedSubview(note("Clean Link Now works even when automatic cleaning is off or paused. A global shortcut can be assigned under Shortcuts. Original links stay in memory only; copying anything else prevents restoration over newer clipboard contents."))

    }

    private func buildActivity() {
        addSection("Automatic actions")
        pauseStatus.lineBreakMode = .byWordWrapping
        pauseStatus.maximumNumberOfLines = 0
        measured.append((pauseStatus, 24))
        content?.addArrangedSubview(pauseStatus)
        buildPauseControls()
        content?.addArrangedSubview(note("Pauses Downloads actions, disk-image offers, and automatic link cleaning without changing your switches. Files received during the pause stay untouched after resuming. Manual actions remain available."))

        buildFeatureStatuses()

        addSection("Recent actions")
        content?.addArrangedSubview(note("The latest 100 file, link, volume, network, Keep Awake and pause actions from this session. History is cleared when Tweaks quits and is never saved to disk."))
        boxed(recentActionsBox)
        content?.addArrangedSubview(button("Clear Recent Actions", #selector(clearRecentActions)))
    }

    private func buildSleep() {
        addSection("Keep Awake")
        addToggles([.keepAwakeHotKey])
        buildAwakeControls()
        sessionLabel.font = .systemFont(ofSize: 12)
        sessionLabel.textColor = .secondaryLabelColor
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
        content?.addArrangedSubview(sessionRow)
        addToggles([.ejectBeforeSleep, .safeEjectHotKey])
        ejectButton.title = "Eject Idle External Drives"
        ejectButton.bezelStyle = .rounded
        ejectButton.font = .systemFont(ofSize: 12)
        ejectButton.target = self
        ejectButton.action = #selector(ejectIdleDrives)
        ejectButton.setContentHuggingPriority(.required, for: .horizontal)
        content?.addArrangedSubview(ejectButton)
        ejectResults.font = .systemFont(ofSize: 11)
        ejectResults.textColor = .secondaryLabelColor
        ejectResults.lineBreakMode = .byWordWrapping
        ejectResults.maximumNumberOfLines = 0
        ejectResults.isSelectable = true
        measured.append((ejectResults, 24))
        content?.addArrangedSubview(ejectResults)
        addToggles([.awakeWhileRendering])
        renderLabel.font = .systemFont(ofSize: 12)
        renderLabel.textColor = .secondaryLabelColor
        renderLabel.lineBreakMode = .byWordWrapping
        renderLabel.maximumNumberOfLines = 0
        measured.append((renderLabel, 24))
        content?.addArrangedSubview(renderLabel)
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
        content?.addArrangedSubview(layoutRow)
        layoutStatus.font = .systemFont(ofSize: 11)
        layoutStatus.textColor = .secondaryLabelColor
        layoutStatus.lineBreakMode = .byWordWrapping
        layoutStatus.maximumNumberOfLines = 0
        measured.append((layoutStatus, 24))
        content?.addArrangedSubview(layoutStatus)
        content?.addArrangedSubview(button("Clear notifications now", #selector(clearNotifications)))

        addSection("Quit when the last window closes")
        addToggles([.quitOnLastWindow])
        appsBox.orientation = .vertical
        appsBox.alignment = .leading
        appsBox.spacing = 4
        pin(appsBox)
        content?.addArrangedSubview(appsBox)
        content?.addArrangedSubview(button("Add App…", #selector(addQuitApp)))
    }

    private func buildNetwork() {
        addSection("Network")
        addToggles([.preferEthernetForVPN, .vpnReconnectReminder, .unmountSharesBeforeSleep, .autoConnectShares])
        sharesBox.orientation = .vertical
        sharesBox.alignment = .leading
        sharesBox.spacing = 4
        pin(sharesBox)
        content?.addArrangedSubview(sharesBox)
        shareField.placeholderString = "smb://server/share"
        shareField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shareField.textColor = .labelColor
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
        content?.addArrangedSubview(addRow)
    }
}
