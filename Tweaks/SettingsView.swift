import AppKit
import Observation

/// The settings window. Built with AppKit so the idle process does not map SwiftUI.
/// Five short pages instead of one long scroll.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let settings: TweakSettings
    let tweaks: TweakController
    let launchAtLogin: LaunchAtLoginController
    var onClose: (() -> Void)?

    private let scroll = NSScrollView()
    private let chrome = NSStackView()
    private var pages: [SettingsPage] = []
    private var selectedTab = SettingsTab.general.rawValue
    /// The column currently being built. Nil once the pages exist.
    var column: NSStackView?
    var toggles: [Tweak: NSSwitch] = [:]
    var accessNotes: [Tweak: NSTextField] = [:]
    var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    let countdownSwitch = NSSwitch()
    let sessionLabel = NSTextField(labelWithString: "")
    let sessionRow = NSStackView()
    let renderLabel = NSTextField(labelWithString: "")
    let sharesBox = NSStackView()
    let appsBox = NSStackView()
    let shareField = NSTextField()
    let addShareButton = NSButton()
    let finderLabel = NSTextField(labelWithString: "")
    let loginSwitch = NSSwitch()
    let loginError = NSTextField(labelWithString: "")
    private let accessRow = NSStackView()
    var measured: [(NSTextField, CGFloat)] = []
    var columnConstraints: [NSLayoutConstraint] = []
    private var shownShares: [String] = []
    private var shownApps: [String] = []
    let volumeBox = NSStackView()
    let duplicateBox = NSStackView()
    let ejectButton = NSButton()
    let ejectResults = NSTextField(labelWithString: "")
    let layoutRow = NSStackView()
    let layoutStatus = NSTextField(labelWithString: "")
    var layoutButtons: [NSButton] = []
    private var shownVolume = ""
    private var shownDuplicates = ""
    private var pinnedToTop = false
    private var fitting = false
    private var tracking = false
    /// Set in windowWillClose. Layout, observation and Finder Sync queries stop with the window.
    private var closed = false

    init(settings: TweakSettings, tweaks: TweakController, launchAtLogin: LaunchAtLoginController) {
        self.settings = settings
        self.tweaks = tweaks
        self.launchAtLogin = launchAtLogin
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Tweaks"
        window.isReleasedWhenClosed = false
        // Paper is a light palette. Aqua keeps switches, buttons and fields on that side in Dark Mode.
        // Leave the titlebar opaque. A transparent one is layer-backed, and that display link
        // keeps running after the window is ordered out for as long as the window object exists.
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Paper.background
        super.init(window: window)
        window.delegate = self
        window.contentView = build()
        window.center()
        sync()
        track()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        closed = true
        window?.delegate = nil
        // Drop the scroll view before the controller goes. A tall document was being
        // redrawn on a display link even after the window had ordered out.
        scroll.documentView = nil
        window?.contentView = nil
        pages.removeAll()
        column = nil
        columnConstraints.removeAll()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        fitStack()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.window?.isVisible == true else { return }
            self.fitStack()
            self.scrollToTop()
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !closed, window?.isVisible == true else { return }
        fitStack()
    }

    // MARK: - Build

    private func build() -> NSView {
        scroll.drawsBackground = true
        scroll.backgroundColor = Paper.background
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = Paper.background
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.borderType = .noBorder

        let banner = NSStackView()
        banner.orientation = .vertical
        banner.alignment = .leading
        banner.spacing = 6
        let bannerText = wrappingLabel("Window layouts, clearing notifications, dismissing Shortcut banners, the green button and blocking Music need permission to look at other apps' windows. Allow Tweaks in System Settings › Privacy & Security › Accessibility. If the switch is already on and this is still here, quit Tweaks and open it again.", size: 12, color: Paper.secondary, reserve: 16)
        let openAccess = button("Open Accessibility Settings", #selector(openAccessibility))
        let relaunch = button("Relaunch", #selector(relaunch))
        let bannerButtons = NSStackView(views: [openAccess, relaunch])
        bannerButtons.orientation = .horizontal
        bannerButtons.spacing = 8
        banner.addArrangedSubview(plainLabel("Some tweaks need Accessibility", size: 13, weight: .semibold, color: Paper.ink))
        banner.addArrangedSubview(bannerText)
        banner.addArrangedSubview(bannerButtons)
        let marker = SettingsRule()
        marker.vertical = true
        accessRow.orientation = .horizontal
        accessRow.alignment = .top
        accessRow.distribution = .fill
        accessRow.spacing = 10
        accessRow.addArrangedSubview(marker)
        accessRow.addArrangedSubview(banner)
        marker.widthAnchor.constraint(equalToConstant: 2).isActive = true
        marker.heightAnchor.constraint(equalTo: banner.heightAnchor).isActive = true
        marker.setContentHuggingPriority(.required, for: .horizontal)
        pin(accessRow)

        let tabs = NSSegmentedControl()
        tabs.segmentCount = SettingsTab.allCases.count
        tabs.trackingMode = .selectOne
        tabs.segmentDistribution = .fillEqually
        tabs.segmentStyle = .roundRect
        tabs.font = .systemFont(ofSize: 12, weight: .medium)
        for tab in SettingsTab.allCases {
            tabs.setLabel(tab.title, forSegment: tab.rawValue)
        }
        tabs.selectedSegment = selectedTab
        tabs.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        pin(tabs)

        chrome.orientation = .vertical
        chrome.alignment = .leading
        chrome.spacing = 12
        chrome.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 8, right: 22)
        chrome.detachesHiddenViews = true
        chrome.addArrangedSubview(accessRow)
        chrome.addArrangedSubview(tabs)

        pages = installPages()
        column = nil
        scroll.documentView = pages.first

        let root = NSView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chrome)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard pages.indices.contains(index), index != selectedTab else { return }
        selectedTab = index
        scroll.documentView = pages[index]
        pinnedToTop = false
        fitStack()
        scrollToTop()
    }

    // MARK: - State

    func sync() {
        guard !closed else { return }
        for (tweak, toggle) in toggles {
            let on = settings.isOn(tweak)
            if toggle.state != (on ? .on : .off) { toggle.state = on ? .on : .off }
            let waiting = tweak.needsAccessibility && !tweaks.hasAccessibility && on
            accessNotes[tweak]?.isHidden = !waiting
        }
        accessRow.isHidden = tweaks.hasAccessibility
        for (action, recorder) in recorders {
            recorder.display(tweaks.shortcuts.shortcut(for: action))
        }
        let countdownOn = tweaks.keepAwake.showsCountdown
        if countdownSwitch.state != (countdownOn ? .on : .off) { countdownSwitch.state = countdownOn ? .on : .off }
        if tweaks.keepAwake.session != nil {
            sessionLabel.stringValue = tweaks.keepAwake.statusLine
            sessionRow.isHidden = false
        } else {
            sessionRow.isHidden = true
        }
        if let holding = tweaks.renderAwake.holdingFor {
            renderLabel.stringValue = "Keeping your Mac awake: \(holding) is rendering"
            renderLabel.isHidden = false
        } else {
            renderLabel.isHidden = true
        }
        rebuildShares()
        rebuildApps()
        rebuildVolumeLimits()
        rebuildDuplicates()
        let ejecting = tweaks.safeEject.busy
        ejectButton.isEnabled = !ejecting
        ejectButton.title = ejecting ? "Ejecting…" : "Eject Idle External Drives"
        let ejectText = tweaks.safeEject.results.joined(separator: "\n")
        if ejectResults.stringValue != ejectText { ejectResults.stringValue = ejectText }
        ejectResults.isHidden = ejectText.isEmpty
        let layoutsReady = settings.isOn(.windowLayouts) && tweaks.hasAccessibility && !tweaks.windowLayouts.busy
        for button in layoutButtons { button.isEnabled = layoutsReady }
        if layoutStatus.stringValue != tweaks.windowLayouts.status { layoutStatus.stringValue = tweaks.windowLayouts.status }
        let finderOn = FinderExtensionBridge.isEnabled()
        finderLabel.stringValue = finderOn == true ? "On in Finder" : (finderOn == false ? "Off in Finder" : "Finder extension")
        let loginOn = launchAtLogin.isEnabled
        if loginSwitch.state != (loginOn ? .on : .off) { loginSwitch.state = loginOn ? .on : .off }
        if let error = launchAtLogin.errorMessage, !error.isEmpty {
            loginError.stringValue = error
            loginError.isHidden = false
        } else {
            loginError.isHidden = true
        }
        fitStack()
    }

    private func rebuildShares() {
        let shares = settings.autoShares
        sharesBox.isHidden = shares.isEmpty
        guard shares != shownShares else { return }
        shownShares = shares
        sharesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for share in shares {
            let label = NSTextField(labelWithString: share)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = Paper.ink
            label.lineBreakMode = .byTruncatingMiddle
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeShare(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(share)
            remove.bezelStyle = .inline
            remove.font = .systemFont(ofSize: 11)
            remove.contentTintColor = Paper.secondary
            sharesBox.addArrangedSubview(labeledRowView(label, trailing: remove, matching: sharesBox))
        }
    }

    private func rebuildApps() {
        let apps = settings.quitApps
        appsBox.isHidden = apps.isEmpty
        guard apps != shownApps else { return }
        shownApps = apps
        appsBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for bundleID in apps {
            let label = plainLabel(Self.appName(for: bundleID), size: 13, weight: .regular, color: Paper.ink)
            label.lineBreakMode = .byTruncatingTail
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeApp(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
            remove.bezelStyle = .inline
            remove.font = .systemFont(ofSize: 11)
            remove.contentTintColor = Paper.secondary
            appsBox.addArrangedSubview(labeledRowView(label, trailing: remove, matching: appsBox))
        }
    }

    private var page: SettingsPage? { scroll.documentView as? SettingsPage }
    private func rebuildVolumeLimits() {
        let model = tweaks.volumeLimits
        let signature = "\(model.devices.map { "\($0.id)|\($0.name)|\($0.supportsVolume)" })\(model.rules.sorted { $0.key < $1.key }.map { "\($0.key)|\($0.value.maximum)|\($0.value.muteOnSwitchAway)" })\(model.status)"
        guard signature != shownVolume else { return }
        shownVolume = signature
        volumeBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let refresh = button("Refresh Devices", #selector(refreshDevices))
        volumeBox.addArrangedSubview(labeledRowView(smallLabel("Output device limits"), trailing: refresh, matching: volumeBox))
        for device in model.devices {
            let toggle = NSSwitch()
            toggle.identifier = NSUserInterfaceItemIdentifier(device.id)
            toggle.state = model.rules[device.id] != nil ? .on : .off
            toggle.isEnabled = device.supportsVolume || model.rules[device.id] != nil
            toggle.target = self
            toggle.action = #selector(volumeRuleToggled(_:))
            let name = plainLabel(device.name, size: 13, weight: .regular, color: Paper.ink)
            name.lineBreakMode = .byTruncatingTail
            volumeBox.addArrangedSubview(labeledRowView(name, trailing: toggle, matching: volumeBox))
            if let rule = model.rules[device.id] {
                let slider = NSSlider(value: Double(rule.maximum), minValue: 0, maxValue: 1, target: self, action: #selector(volumeLimitChanged(_:)))
                slider.identifier = NSUserInterfaceItemIdentifier(device.id)
                slider.numberOfTickMarks = 21
                slider.allowsTickMarkValuesOnly = true
                slider.isContinuous = false
                slider.isEnabled = device.supportsVolume
                let percent = smallLabel("\(Int((rule.maximum * 100).rounded()))%")
                percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
                volumeBox.addArrangedSubview(labeledRowView(slider, trailing: percent, matching: volumeBox))
                let mute = NSButton(checkboxWithTitle: "Mute the next output when switching away from this device", target: self, action: #selector(volumeMuteToggled(_:)))
                mute.identifier = NSUserInterfaceItemIdentifier(device.id)
                mute.state = rule.muteOnSwitchAway ? .on : .off
                mute.font = .systemFont(ofSize: 11)
                volumeBox.addArrangedSubview(mute)
            }
            if !device.supportsVolume {
                volumeBox.addArrangedSubview(smallLabel("Uses its own hardware volume control."))
            }
        }
        for uid in model.rules.keys.filter({ uid in !model.devices.contains(where: { $0.id == uid }) }).sorted() {
            let forget = NSButton(title: "Forget", target: self, action: #selector(forgetVolumeRule(_:)))
            forget.identifier = NSUserInterfaceItemIdentifier(uid)
            forget.bezelStyle = .inline
            forget.font = .systemFont(ofSize: 11)
            volumeBox.addArrangedSubview(labeledRowView(smallLabel("\(model.rules[uid]?.name ?? uid) · disconnected"), trailing: forget, matching: volumeBox))
        }
        volumeBox.addArrangedSubview(smallLabel(model.status))
        fitStack()
    }

    private func rebuildDuplicates() {
        let model = tweaks.duplicates
        let signature = "\(model.matches.map(\.id))\(model.busy)\(model.status)"
        guard signature != shownDuplicates else { return }
        shownDuplicates = signature
        duplicateBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        duplicateBox.addArrangedSubview(smallLabel(model.status))
        for match in model.matches {
            duplicateBox.addArrangedSubview(plainLabel("New: \(match.newFile.lastPathComponent)", size: 12, weight: .regular, color: Paper.ink))
            let size = ByteCountFormatter.string(fromByteCount: match.bytes, countStyle: .file)
            duplicateBox.addArrangedSubview(smallLabel("Matches: \(match.existingFile.lastPathComponent) · \(size)"))
            let buttons = [button("Show Both", #selector(showDuplicate(_:))),
                           button("Keep Both", #selector(keepDuplicate(_:))),
                           button("Trash New Copy", #selector(trashDuplicate(_:)))]
            for button in buttons {
                button.identifier = NSUserInterfaceItemIdentifier(match.id)
                button.isEnabled = !model.busy
            }
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 8
            duplicateBox.addArrangedSubview(row)
        }
        duplicateBox.isHidden = false
        fitStack()
    }

    private func fitStack() {
        // Nothing to lay out while the window is closed or ordered out. A hidden document
        // that keeps invalidating itself is what held a display link with no window on screen.
        guard !closed, !fitting, window?.isVisible == true, let page else { return }
        fitting = true
        defer { fitting = false }
        // contentView bounds, not contentSize: contentSize shrinks when a scroller appears,
        // which was changing the document width and scheduling another layout.
        let boundsWidth = window?.contentView?.bounds.width ?? 0
        let width = boundsWidth > 1 ? boundsWidth : 500
        let inner = max(200, width - page.column.edgeInsets.left - page.column.edgeInsets.right)
        for constraint in columnConstraints where constraint.constant != inner {
            constraint.constant = inner
        }
        for (label, reserve) in measured {
            let limit = max(120, inner - reserve)
            if label.preferredMaxLayoutWidth != limit { label.preferredMaxLayoutWidth = limit }
        }
        if page.frame.width != width { page.frame.size.width = width }
        if page.column.frame.width != width { page.column.frame.size.width = width }
        chrome.layoutSubtreeIfNeeded()
        page.column.layoutSubtreeIfNeeded()
        let height = max(page.column.fittingSize.height, 1)
        let next = NSRect(x: 0, y: 0, width: width, height: height)
        let columnFrame = NSRect(x: 0, y: 0, width: width, height: height)
        if page.frame != next || page.column.frame != columnFrame {
            let origin = scroll.contentView.bounds.origin
            page.frame = next
            page.column.frame = columnFrame
            if pinnedToTop {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    /// Flipped page: the top is y = 0. Runs once the window is visible, so the clip
    /// view isn't still using a placeholder height from before it was on screen.
    private func scrollToTop() {
        guard window?.isVisible == true else { return }
        pinnedToTop = true
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func track() {
        guard !closed, !tracking else { return }
        tracking = true
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.tweaks.hasAccessibility
            _ = self.tweaks.keepAwake.session
            _ = self.tweaks.keepAwake.statusLine
            _ = self.tweaks.keepAwake.showsCountdown
            _ = self.tweaks.renderAwake.holdingFor
            _ = self.launchAtLogin.isEnabled
            _ = self.launchAtLogin.errorMessage
            _ = self.settings.autoShares
            _ = self.settings.quitApps
            _ = self.tweaks.volumeLimits.devices
            _ = self.tweaks.volumeLimits.rules
            _ = self.tweaks.volumeLimits.status
            _ = self.tweaks.duplicates.matches
            _ = self.tweaks.duplicates.busy
            _ = self.tweaks.duplicates.status
            _ = self.tweaks.safeEject.busy
            _ = self.tweaks.safeEject.results
            _ = self.tweaks.windowLayouts.busy
            _ = self.tweaks.windowLayouts.status
            for tweak in Tweak.allCases { _ = self.settings.isOn(tweak) }
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.tracking = false
                    self.sync()
                    self.track()
                }
            }
        }
    }

    // MARK: - Actions

    @objc func tweakToggled(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue, let tweak = Tweak(rawValue: id) else { return }
        settings.set(tweak, on: sender.state == .on)
    }

    @objc func countdownChanged(_ sender: NSSwitch) {
        tweaks.keepAwake.showsCountdown = sender.state == .on
    }

    @objc func loginChanged(_ sender: NSSwitch) {
        launchAtLogin.setEnabled(sender.state == .on)
        sync()
    }

    @objc func stopKeepAwake() {
        tweaks.keepAwake.stop(reason: "Stopped.")
    }

    @objc func clearNotifications() {
        tweaks.clearNotifications()
    }

    @objc func chooseImages() {
        tweaks.imageActions.choose()
    }

    @objc func ejectIdleDrives() {
        Task { await tweaks.safeEject.ejectIdleDrives() }
    }

    @objc func saveLayout() {
        Task { await tweaks.windowLayouts.save() }
    }

    @objc func restoreLayout() {
        Task { await tweaks.windowLayouts.restore() }
    }

    @objc func forgetLayout() {
        tweaks.windowLayouts.forgetCurrent()
    }

    @objc private func refreshDevices() {
        tweaks.volumeLimits.refreshDevices()
    }

    @objc private func volumeRuleToggled(_ sender: NSSwitch) {
        guard let uid = sender.identifier?.rawValue,
              let device = tweaks.volumeLimits.devices.first(where: { $0.id == uid }) else { return }
        tweaks.volumeLimits.setRule(sender.state == .on ? .init(name: device.name, maximum: 0.4) : nil, for: uid)
    }

    @objc private func volumeLimitChanged(_ sender: NSSlider) {
        guard let uid = sender.identifier?.rawValue, var rule = tweaks.volumeLimits.rules[uid] else { return }
        rule.maximum = Float(sender.doubleValue)
        tweaks.volumeLimits.setRule(rule, for: uid)
    }

    @objc private func volumeMuteToggled(_ sender: NSButton) {
        guard let uid = sender.identifier?.rawValue, var rule = tweaks.volumeLimits.rules[uid] else { return }
        rule.muteOnSwitchAway = sender.state == .on
        tweaks.volumeLimits.setRule(rule, for: uid)
    }

    @objc private func forgetVolumeRule(_ sender: NSButton) {
        guard let uid = sender.identifier?.rawValue else { return }
        tweaks.volumeLimits.setRule(nil, for: uid)
    }

    private func duplicate(for sender: NSButton) -> DuplicateMatch? {
        guard let id = sender.identifier?.rawValue else { return nil }
        return tweaks.duplicates.matches.first { $0.id == id }
    }

    @objc private func showDuplicate(_ sender: NSButton) {
        guard let match = duplicate(for: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([match.newFile, match.existingFile])
    }

    @objc private func keepDuplicate(_ sender: NSButton) {
        guard let match = duplicate(for: sender) else { return }
        tweaks.duplicates.keep(match)
    }

    @objc private func trashDuplicate(_ sender: NSButton) {
        guard let match = duplicate(for: sender) else { return }
        Task { await tweaks.duplicates.trash(match) }
    }

    @objc private func openAccessibility() {
        AX.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func relaunch() {
        AX.relaunch()
    }

    @objc func addShare() {
        let trimmed = shareField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.host() != nil, !settings.autoShares.contains(trimmed) else { return }
        settings.setAutoShares(settings.autoShares + [trimmed])
        shareField.stringValue = ""
    }

    @objc func removeShare(_ sender: NSButton) {
        guard let share = sender.identifier?.rawValue else { return }
        settings.setAutoShares(settings.autoShares.filter { $0 != share })
    }

    @objc func addQuitApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        settings.setQuitApps(Array(Set(settings.quitApps + added)).sorted { Self.appName(for: $0) < Self.appName(for: $1) })
    }

    @objc func removeApp(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        settings.setQuitApps(settings.quitApps.filter { $0 != bundleID })
    }

    @objc func showFinderExtensions() {
        FinderExtensionBridge.showManagement()
    }

    @objc func quitTweaks() {
        AppDelegate.reallyQuit = true
        NSApp.terminate(nil)
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
