import AppKit
import Darwin
import ObjectiveC
import Observation
import os

/// Finder Sync is loaded only while this window is open. The idle app does not link it.
enum FinderExtensionBridge {
    private static let loaded = OSAllocatedUnfairLock(initialState: false)

    static func prepare() -> Bool {
        let firstTime = loaded.withLock { value -> Bool in
            if value { return false }
            value = true
            return true
        }
        if !firstTime { return NSClassFromString("FIFinderSyncController") != nil }
        let path = "/System/Library/Frameworks/FinderSync.framework/FinderSync"
        return dlopen(path, RTLD_LAZY) != nil && NSClassFromString("FIFinderSyncController") != nil
    }

    static func isEnabled() -> Bool? {
        guard prepare(), let cls = NSClassFromString("FIFinderSyncController") else { return nil }
        guard let controller = classObject(cls, "defaultController") else { return nil }
        return instanceBool(controller, "isExtensionEnabled")
    }

    static func showManagement() {
        guard prepare(), let cls = NSClassFromString("FIFinderSyncController") else { return }
        classVoid(cls, "showExtensionManagementInterface")
    }

    private static func classObject(_ cls: AnyClass, _ name: String) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let imp = unsafeBitCast(class_getMethodImplementation(meta, sel), to: Fn.self)
        return imp(cls, sel)?.takeUnretainedValue()
    }

    private static func classVoid(_ cls: AnyClass, _ name: String) {
        let sel = NSSelectorFromString(name)
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let imp = unsafeBitCast(class_getMethodImplementation(meta, sel), to: Fn.self)
        imp(cls, sel)
    }

    private static func instanceBool(_ object: AnyObject, _ name: String) -> Bool? {
        let sel = NSSelectorFromString(name)
        guard let cls = object_getClass(object), class_respondsToSelector(cls, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let imp = unsafeBitCast(class_getMethodImplementation(cls, sel), to: Fn.self)
        return imp(object, sel)
    }
}

/// The settings window. Built with AppKit so the idle process does not map SwiftUI.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: TweakSettings
    private let tweaks: TweakController
    private let launchAtLogin: LaunchAtLoginController
    var onClose: (() -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var toggles: [Tweak: NSSwitch] = [:]
    private var accessNotes: [Tweak: NSTextField] = [:]
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private let banner = NSStackView()
    private let countdownSwitch = NSSwitch()
    private let sessionLabel = NSTextField(labelWithString: "")
    private let sessionRow = NSStackView()
    private let renderLabel = NSTextField(labelWithString: "")
    private let sharesBox = NSStackView()
    private let appsBox = NSStackView()
    private let shareField = NSTextField()
    private let addShareButton = NSButton()
    private let finderLabel = NSTextField(labelWithString: "")
    private let loginSwitch = NSSwitch()
    private let loginError = NSTextField(labelWithString: "")
    private let accessRow = NSStackView()
    private var measured: [(NSTextField, CGFloat)] = []
    private var columnConstraints: [NSLayoutConstraint] = []
    private var shownShares: [String] = []
    private var shownApps: [String] = []
    private let volumeBox = NSStackView()
    private let duplicateBox = NSStackView()
    private let ejectButton = NSButton()
    private let ejectResults = NSTextField(labelWithString: "")
    private let layoutRow = NSStackView()
    private let layoutStatus = NSTextField(labelWithString: "")
    private var layoutButtons: [NSButton] = []
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
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
            self.pinToTopIfNeeded()
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !closed, window?.isVisible == true else { return }
        fitStack()
        pinToTopIfNeeded()
    }

    // MARK: - Build

    private func build() -> NSView {
        scroll.drawsBackground = true
        scroll.backgroundColor = Paper.background
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.borderType = .noBorder

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 24, right: 22)
        stack.detachesHiddenViews = true
        scroll.documentView = stack

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
        let marker = Rule()
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
        stack.addArrangedSubview(accessRow)

        addSection("Shortcuts")
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(shortcut: tweaks.shortcuts.shortcut(for: action)) { [weak self] shortcut in
                self?.tweaks.shortcuts.set(shortcut, for: action)
            }
            recorders[action] = recorder
            stack.addArrangedSubview(labeledRow(action.title, trailing: recorder, reserve: 156))
        }
        stack.addArrangedSubview(note("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. Hyper is ⌃⌥⇧⌘."))

        addSection("Keyboard and sound")
        addToggles([.capsLockNoDelay, .wakeVolumeLimit, .muteIcon, .blockMusicLaunch, .deviceVolumeLimits])
        boxed(volumeBox)
        tweaks.volumeLimits.refreshDevices()

        addSection("Downloads and clipboard")
        addToggles([.lowercaseExtensions, .calendarInvites, .dmgInstaller, .unzipDownloads, .cleanCopiedLinks, .duplicateDownloads])
        boxed(duplicateBox)

        addSection("Sleep")
        addToggles([.keepAwakeHotKey])
        countdownSwitch.target = self
        countdownSwitch.action = #selector(countdownChanged(_:))
        stack.addArrangedSubview(labeledRow("Show time left next to the cup", trailing: countdownSwitch))
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
        stack.addArrangedSubview(sessionRow)
        addToggles([.ejectBeforeSleep, .safeEjectHotKey])
        ejectButton.title = "Eject Idle External Drives"
        ejectButton.bezelStyle = .rounded
        ejectButton.font = .systemFont(ofSize: 12)
        ejectButton.target = self
        ejectButton.action = #selector(ejectIdleDrives)
        ejectButton.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(ejectButton)
        ejectResults.font = .systemFont(ofSize: 11)
        ejectResults.textColor = Paper.secondary
        ejectResults.lineBreakMode = .byWordWrapping
        ejectResults.maximumNumberOfLines = 0
        ejectResults.isSelectable = true
        measured.append((ejectResults, 0))
        stack.addArrangedSubview(ejectResults)
        addToggles([.awakeWhileRendering])
        renderLabel.font = .systemFont(ofSize: 12)
        renderLabel.textColor = Paper.secondary
        renderLabel.lineBreakMode = .byWordWrapping
        renderLabel.maximumNumberOfLines = 0
        measured.append((renderLabel, 0))
        stack.addArrangedSubview(renderLabel)

        addSection("Windows and notifications")
        addToggles([.clearNotificationsHotKey, .dismissShortcutNotifications, .greenButtonFills, .windowLayouts])
        layoutButtons = [button("Save This Layout", #selector(saveLayout)),
                         button("Restore Layout", #selector(restoreLayout)),
                         button("Forget Layout", #selector(forgetLayout))]
        layoutRow.setViews(layoutButtons, in: .leading)
        layoutRow.orientation = .horizontal
        layoutRow.spacing = 8
        stack.addArrangedSubview(layoutRow)
        layoutStatus.font = .systemFont(ofSize: 11)
        layoutStatus.textColor = Paper.secondary
        layoutStatus.lineBreakMode = .byWordWrapping
        layoutStatus.maximumNumberOfLines = 0
        measured.append((layoutStatus, 0))
        stack.addArrangedSubview(layoutStatus)
        stack.addArrangedSubview(button("Clear notifications now", #selector(clearNotifications)))

        addSection("Network")
        addToggles([.unmountSharesBeforeSleep, .autoConnectShares])
        sharesBox.orientation = .vertical
        sharesBox.alignment = .leading
        sharesBox.spacing = 4
        pin(sharesBox)
        stack.addArrangedSubview(sharesBox)
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
        stack.addArrangedSubview(addRow)

        addSection("Finder")
        stack.addArrangedSubview(button("Quick Image Actions…", #selector(chooseImages)))
        stack.addArrangedSubview(note("Convert or resize selected images and optionally remove metadata. Originals are kept. Also available from Finder's right-click menu."))
        stack.addArrangedSubview(note("Copy Path shortens NAS, Box and Google Drive roots. Copy Original Path and Inspect Media are on the same menu. Turn the extension on under Finder Extensions."))
        finderLabel.font = .systemFont(ofSize: 12)
        finderLabel.textColor = Paper.secondary
        finderLabel.lineBreakMode = .byTruncatingTail
        let finderButton = button("Finder Extensions…", #selector(showFinderExtensions))
        stack.addArrangedSubview(labeledRowView(finderLabel, trailing: finderButton))

        addSection("Quit when the last window closes")
        addToggles([.quitOnLastWindow])
        appsBox.orientation = .vertical
        appsBox.alignment = .leading
        appsBox.spacing = 4
        pin(appsBox)
        stack.addArrangedSubview(appsBox)
        stack.addArrangedSubview(button("Add App…", #selector(addQuitApp)))

        addSection("Launch")
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        stack.addArrangedSubview(labeledRow("Launch at login", trailing: loginSwitch))
        loginError.font = .systemFont(ofSize: 11)
        loginError.textColor = Paper.secondary
        loginError.lineBreakMode = .byWordWrapping
        loginError.maximumNumberOfLines = 0
        measured.append((loginError, 0))
        stack.addArrangedSubview(loginError)
        stack.addArrangedSubview(note("Closing this window leaves Tweaks running, with no Dock icon. Open it again from Finder or Spotlight."))
        let quit = button("Quit Tweaks", #selector(quitTweaks))
        stack.addArrangedSubview(quit)

        return scroll
    }

    /// A vertical box whose rows are rebuilt when its model changes (like the share list).
    private func boxed(_ box: NSStackView) {
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        pin(box)
        stack.addArrangedSubview(box)
    }

    private func smallLabel(_ text: String, color: NSColor = Paper.secondary) -> NSTextField {
        let label = plainLabel(text, size: 11, weight: .regular, color: color)
        measured.append((label, 0))
        return label
    }

    private func addSection(_ title: String) {
        if let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(20, after: last)
        }
        let header = plainLabel(title, size: 11, weight: .semibold, color: Paper.secondary)
        let rule = Rule()
        pin(rule)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let block = NSStackView(views: [header, rule])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4
        stack.addArrangedSubview(block)
    }

    private func addToggles(_ tweaks: [Tweak]) {
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
            stack.addArrangedSubview(labeledRowView(text, trailing: toggle))
        }
    }

    private func labeledRow(_ title: String, trailing: NSView, reserve: CGFloat = 72) -> NSView {
        let label = plainLabel(title, size: 13, weight: .regular, color: Paper.ink)
        measured.append((label, reserve))
        return labeledRowView(label, trailing: trailing)
    }

    /// Title on the left, control on the right, across the column. `matching` is for rows
    /// added later inside an already-pinned box (the share list, the app list).
    private func labeledRowView(_ leading: NSView, trailing: NSView, matching box: NSView? = nil) -> NSView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.distribution = .fill
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let box {
            let width = row.widthAnchor.constraint(equalTo: box.widthAnchor)
            width.priority = NSLayoutConstraint.Priority(999)
            width.isActive = true
        } else {
            pin(row)
        }
        return row
    }

    /// Column width, updated once the scroll view knows how wide it is.
    private func pin(_ view: NSView) {
        let width = view.widthAnchor.constraint(equalToConstant: 456)
        width.priority = NSLayoutConstraint.Priority(999)
        width.isActive = true
        columnConstraints.append(width)
    }

    private func plainLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func wrappingLabel(_ text: String, size: CGFloat, color: NSColor, reserve: CGFloat = 0) -> NSTextField {
        let label = plainLabel(text, size: size, weight: .regular, color: color)
        measured.append((label, reserve))
        return label
    }

    private func note(_ text: String) -> NSTextField {
        wrappingLabel(text, size: 11, color: Paper.secondary)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
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
        guard !closed, !fitting, window?.isVisible == true else { return }
        fitting = true
        defer { fitting = false }
        // contentView bounds, not contentSize: contentSize shrinks when a scroller appears,
        // which was changing the document width and scheduling another layout.
        let boundsWidth = window?.contentView?.bounds.width ?? 0
        let width = boundsWidth > 1 ? boundsWidth : 500
        let inner = max(200, width - stack.edgeInsets.left - stack.edgeInsets.right)
        for constraint in columnConstraints where constraint.constant != inner {
            constraint.constant = inner
        }
        for (label, reserve) in measured {
            let limit = max(120, inner - reserve)
            if label.preferredMaxLayoutWidth != limit { label.preferredMaxLayoutWidth = limit }
        }
        stack.layoutSubtreeIfNeeded()
        let height = max(stack.fittingSize.height, 200)
        let next = NSRect(x: 0, y: 0, width: width, height: height)
        if stack.frame != next {
            let origin = scroll.contentView.bounds.origin
            stack.frame = next
            if pinnedToTop {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    /// The document view is not flipped, so a tall stack opens on its last section until
    /// this runs once, after the window is visible and the clip view has its real height.
    private func pinToTopIfNeeded() {
        guard !pinnedToTop, let window, window.isVisible else { return }
        let clip = scroll.contentView
        guard clip.bounds.height > window.contentLayoutRect.height * 0.8, stack.frame.height > 1 else { return }
        pinnedToTop = true
        let y = max(0, stack.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
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

    @objc private func tweakToggled(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue, let tweak = Tweak(rawValue: id) else { return }
        settings.set(tweak, on: sender.state == .on)
    }

    @objc private func countdownChanged(_ sender: NSSwitch) {
        tweaks.keepAwake.showsCountdown = sender.state == .on
    }

    @objc private func loginChanged(_ sender: NSSwitch) {
        launchAtLogin.setEnabled(sender.state == .on)
        sync()
    }

    @objc private func stopKeepAwake() {
        tweaks.keepAwake.stop(reason: "Stopped.")
    }

    @objc private func clearNotifications() {
        tweaks.clearNotifications()
    }

    @objc private func chooseImages() {
        tweaks.imageActions.choose()
    }

    @objc private func ejectIdleDrives() {
        Task { await tweaks.safeEject.ejectIdleDrives() }
    }

    @objc private func saveLayout() {
        Task { await tweaks.windowLayouts.save() }
    }

    @objc private func restoreLayout() {
        Task { await tweaks.windowLayouts.restore() }
    }

    @objc private func forgetLayout() {
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

    @objc private func addShare() {
        let trimmed = shareField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.host() != nil, !settings.autoShares.contains(trimmed) else { return }
        settings.setAutoShares(settings.autoShares + [trimmed])
        shareField.stringValue = ""
    }

    @objc private func removeShare(_ sender: NSButton) {
        guard let share = sender.identifier?.rawValue else { return }
        settings.setAutoShares(settings.autoShares.filter { $0 != share })
    }

    @objc private func addQuitApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        settings.setQuitApps(Array(Set(settings.quitApps + added)).sorted { Self.appName(for: $0) < Self.appName(for: $1) })
    }

    @objc private func removeApp(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        settings.setQuitApps(settings.quitApps.filter { $0 != bundleID })
    }

    @objc private func showFinderExtensions() {
        FinderExtensionBridge.showManagement()
    }

    @objc private func quitTweaks() {
        AppDelegate.reallyQuit = true
        NSApp.terminate(nil)
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// A 1pt hairline, or a 2pt vertical mark beside the Accessibility note.
@MainActor
private final class Rule: NSView {
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
