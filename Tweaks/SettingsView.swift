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
    private var wrapping: [NSTextField] = []
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
    private var tracking = false

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
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        fitStack()
    }

    // MARK: - Build

    private func build() -> NSView {
        scroll.drawsBackground = true
        scroll.backgroundColor = Paper.background
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 22, bottom: 22, right: 22)
        stack.detachesHiddenViews = true
        scroll.documentView = stack

        banner.orientation = .vertical
        banner.alignment = .leading
        banner.spacing = 6
        banner.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        banner.wantsLayer = true
        banner.layer?.backgroundColor = Paper.wash.cgColor
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = Paper.line.cgColor
        banner.layer?.cornerRadius = 2
        let bannerText = wrappingLabel("Clearing notifications, dismissing Shortcut banners, the green button and blocking Music need permission to look at other apps' windows. Allow Tweaks in System Settings › Privacy & Security › Accessibility. If the switch is already on and this is still here, quit Tweaks and open it again.", size: 12, color: Paper.secondary)
        let openAccess = button("Open Accessibility Settings", #selector(openAccessibility))
        let relaunch = button("Relaunch", #selector(relaunch))
        let bannerButtons = NSStackView(views: [openAccess, relaunch])
        bannerButtons.orientation = .horizontal
        bannerButtons.spacing = 8
        banner.addArrangedSubview(plainLabel("Some tweaks need Accessibility", size: 13, weight: .semibold, color: Paper.ink))
        banner.addArrangedSubview(bannerText)
        banner.addArrangedSubview(bannerButtons)
        stack.addArrangedSubview(banner)

        addSection("Shortcuts")
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(shortcut: tweaks.shortcuts.shortcut(for: action)) { [weak self] shortcut in
                self?.tweaks.shortcuts.set(shortcut, for: action)
            }
            recorders[action] = recorder
            stack.addArrangedSubview(labeledRow(action.title, trailing: recorder))
        }
        stack.addArrangedSubview(note("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. Hyper is ⌃⌥⇧⌘."))

        addSection("Keyboard and sound")
        addToggles([.capsLockNoDelay, .wakeVolumeLimit, .muteIcon, .blockMusicLaunch])

        addSection("Downloads and clipboard")
        addToggles([.lowercaseExtensions, .calendarInvites, .dmgInstaller, .unzipDownloads, .cleanCopiedLinks])

        addSection("Sleep")
        addToggles([.keepAwakeHotKey])
        countdownSwitch.target = self
        countdownSwitch.action = #selector(countdownChanged(_:))
        stack.addArrangedSubview(labeledRow("Show time left next to the cup", trailing: countdownSwitch))
        sessionLabel.font = .systemFont(ofSize: 12)
        sessionLabel.textColor = Paper.secondary
        sessionLabel.lineBreakMode = .byTruncatingTail
        let stop = button("Stop", #selector(stopKeepAwake))
        sessionRow.orientation = .horizontal
        sessionRow.spacing = 8
        sessionRow.addArrangedSubview(sessionLabel)
        sessionRow.addArrangedSubview(stop)
        stack.addArrangedSubview(sessionRow)
        addToggles([.ejectBeforeSleep, .awakeWhileRendering])
        renderLabel.font = .systemFont(ofSize: 12)
        renderLabel.textColor = Paper.secondary
        stack.addArrangedSubview(renderLabel)

        addSection("Windows and notifications")
        addToggles([.clearNotificationsHotKey, .dismissShortcutNotifications, .greenButtonFills])
        stack.addArrangedSubview(button("Clear notifications now", #selector(clearNotifications)))

        addSection("Network")
        addToggles([.unmountSharesBeforeSleep, .autoConnectShares])
        sharesBox.orientation = .vertical
        sharesBox.alignment = .leading
        sharesBox.spacing = 4
        stack.addArrangedSubview(sharesBox)
        shareField.placeholderString = "smb://server/share"
        shareField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shareField.target = self
        shareField.action = #selector(addShare)
        addShareButton.title = "Add"
        addShareButton.bezelStyle = .rounded
        addShareButton.target = self
        addShareButton.action = #selector(addShare)
        addShareButton.setContentHuggingPriority(.required, for: .horizontal)
        let addRow = NSStackView(views: [shareField, addShareButton])
        addRow.orientation = .horizontal
        addRow.spacing = 8
        shareField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        stack.addArrangedSubview(addRow)

        addSection("Finder")
        stack.addArrangedSubview(note("Copy Path shortens NAS, Box and Google Drive roots. Copy Original Path and Inspect Media are on the same menu. Turn the extension on under Finder Extensions."))
        finderLabel.font = .systemFont(ofSize: 12)
        finderLabel.textColor = Paper.secondary
        let finderButton = button("Finder Extensions…", #selector(showFinderExtensions))
        stack.addArrangedSubview(labeledRowView(finderLabel, trailing: finderButton))

        addSection("Quit when the last window closes")
        addToggles([.quitOnLastWindow])
        appsBox.orientation = .vertical
        appsBox.alignment = .leading
        appsBox.spacing = 4
        stack.addArrangedSubview(appsBox)
        stack.addArrangedSubview(button("Add App…", #selector(addQuitApp)))

        addSection("Launch")
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        stack.addArrangedSubview(labeledRow("Launch at login", trailing: loginSwitch))
        loginError.font = .systemFont(ofSize: 11)
        loginError.textColor = Paper.secondary
        wrapping.append(loginError)
        stack.addArrangedSubview(loginError)
        stack.addArrangedSubview(note("Closing this window leaves Tweaks running, with no Dock icon. Open it again from Finder or Spotlight."))
        let quit = button("Quit Tweaks", #selector(quitTweaks))
        stack.addArrangedSubview(quit)

        return scroll
    }

    private func addSection(_ title: String) {
        let header = plainLabel(title, size: 11, weight: .semibold, color: Paper.secondary)
        let rule = NSBox()
        rule.boxType = .separator
        rule.title = ""
        let block = NSStackView(views: [header, rule])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4
        rule.widthAnchor.constraint(equalToConstant: 456).isActive = true
        stack.addArrangedSubview(block)
    }

    private func addToggles(_ tweaks: [Tweak]) {
        for tweak in tweaks {
            let title = plainLabel(tweak.title, size: 13, weight: .regular, color: Paper.ink)
            let detail = wrappingLabel(tweak.detail, size: 11, color: Paper.secondary)
            let note = wrappingLabel("Waiting for Accessibility permission", size: 11, color: Paper.secondary)
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

    private func labeledRow(_ title: String, trailing: NSView) -> NSView {
        labeledRowView(plainLabel(title, size: 13, weight: .regular, color: Paper.ink), trailing: trailing)
    }

    private func labeledRowView(_ leading: NSView, trailing: NSView) -> NSView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func plainLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func wrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = plainLabel(text, size: size, weight: .regular, color: color)
        wrapping.append(label)
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
        for (tweak, toggle) in toggles {
            let on = settings.isOn(tweak)
            if toggle.state != (on ? .on : .off) { toggle.state = on ? .on : .off }
            let waiting = tweak.needsAccessibility && !tweaks.hasAccessibility && on
            accessNotes[tweak]?.isHidden = !waiting
        }
        banner.isHidden = tweaks.hasAccessibility
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
        sharesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for share in settings.autoShares {
            let label = NSTextField(labelWithString: share)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = Paper.ink
            label.lineBreakMode = .byTruncatingMiddle
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeShare(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(share)
            remove.bezelStyle = .inline
            remove.font = .systemFont(ofSize: 11)
            remove.contentTintColor = Paper.secondary
            sharesBox.addArrangedSubview(labeledRowView(label, trailing: remove))
        }
        sharesBox.isHidden = settings.autoShares.isEmpty
    }

    private func rebuildApps() {
        appsBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for bundleID in settings.quitApps {
            let label = plainLabel(Self.appName(for: bundleID), size: 13, weight: .regular, color: Paper.ink)
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeApp(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
            remove.bezelStyle = .inline
            remove.font = .systemFont(ofSize: 11)
            remove.contentTintColor = Paper.secondary
            appsBox.addArrangedSubview(labeledRowView(label, trailing: remove))
        }
        appsBox.isHidden = settings.quitApps.isEmpty
    }

    private func fitStack() {
        let width = scroll.contentSize.width > 1 ? scroll.contentSize.width : 500
        let textWidth = max(160, width - 22 - 22 - 80)
        for label in wrapping {
            label.preferredMaxLayoutWidth = textWidth
        }
        let height = max(stack.fittingSize.height, 200)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private func track() {
        guard !tracking else { return }
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
            for tweak in Tweak.allCases { _ = self.settings.isOn(tweak) }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
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
