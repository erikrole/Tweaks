import AppKit

extension SettingsWindowController {
    func buildPauseControls() {
        pauseChoice.addItems(withTitles: ["15 minutes", "30 minutes", "60 minutes", "Until a chosen time…"])
        pauseChoice.selectItem(at: 1)
        pauseChoice.setAccessibilityLabel("Automatic actions pause duration")
        pauseChoice.target = self; pauseChoice.action = #selector(pauseChoiceChanged)
        pauseDate.datePickerStyle = .textFieldAndStepper
        pauseDate.datePickerElements = [.yearMonthDay, .hourMinute]
        pauseDate.dateValue = Date().addingTimeInterval(3600)
        pauseDate.setAccessibilityLabel("Automatic actions resume time")
        pauseDate.isHidden = true
        content?.addArrangedSubview(pauseChoice)
        content?.addArrangedSubview(pauseDate)
        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self; pauseButton.action = #selector(applyAutomationPause)
        resumePauseButton.title = "Resume Now"
        resumePauseButton.bezelStyle = .rounded
        resumePauseButton.target = self; resumePauseButton.action = #selector(resumeAutomationPause)
        let row = NSStackView(views: [pauseButton, resumePauseButton]); row.spacing = 8
        content?.addArrangedSubview(row)
        pauseError.textColor = .systemOrange
        pauseError.font = .systemFont(ofSize: 11)
        pauseError.isHidden = true
        content?.addArrangedSubview(pauseError)
    }

    func buildAwakeControls() {
        awakeMode.addItems(withTitles: ["Away — dim when idle, stay unlocked", "Screen stays on"])
        awakeMode.setAccessibilityLabel("Keep Awake mode")
        if tweaks.keepAwake.session?.dimsWhenIdle == false { awakeMode.selectItem(at: 1) }
        content?.addArrangedSubview(awakeMode)
        awakeEnd.onLayoutChange = { [weak self] in self?.sync() }
        awakeEnd.translatesAutoresizingMaskIntoConstraints = false
        pin(awakeEnd)
        content?.addArrangedSubview(awakeEnd)
        content?.addArrangedSubview(button("Start Session", #selector(startAwakeSession)))
        content?.addArrangedSubview(note("Starting replaces only the manual Keep Awake session. Render-based keep-awake runs independently. Your shortcut behavior and saved defaults stay the same."))
    }

    func buildFeatureStatuses() {
        addSection("Feature status")
        let summary = note("")
        awakeSummary = summary
        content?.addArrangedSubview(summary)
        showAllStatuses.target = self; showAllStatuses.action = #selector(statusVisibilityChanged)
        content?.addArrangedSubview(showAllStatuses)
        for tweak in Tweak.allCases {
            let title = plainLabel(tweak.title, size: 12, weight: .medium, color: .labelColor)
            let state = wrappingLabel("", size: 11, color: .secondaryLabelColor)
            activityStatusLabels[tweak] = state
            let row = NSStackView(views: [title, state])
            row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
            activityStatusRows[tweak] = row
            content?.addArrangedSubview(row)
            pin(row)
        }
    }

    @objc func statusVisibilityChanged() { sync() }

    @objc func pauseChoiceChanged() {
        pauseDate.isHidden = pauseChoice.indexOfSelectedItem != 3
        pauseError.isHidden = true
        sync()
    }

    @objc func applyAutomationPause() {
        let now = Date()
        let end = pauseChoice.indexOfSelectedItem == 3 ? pauseDate.dateValue
            : now.addingTimeInterval([900.0, 1800, 3600][max(0, min(2, pauseChoice.indexOfSelectedItem))])
        pauseError.isHidden = tweaks.automationPause.pause(until: end, now: now)
        pauseError.stringValue = "Choose a future resume time."
        sync()
    }

    @objc func resumeAutomationPause() { tweaks.automationPause.resume(); sync() }

    @objc func startAwakeSession() {
        guard let until = awakeEnd.resolve() else { sync(); return }
        if awakeMode.indexOfSelectedItem == 0 { tweaks.keepAwake.startAway(until: until) }
        else { tweaks.keepAwake.startScreenOn(until: until) }
        sync()
    }
}
