import AppKit

enum SessionEndChoice: Int, CaseIterable {
    case indefinitely, halfHour, oneHour, twoHours, fourHours, time, appQuits
    var title: String {
        switch self {
        case .indefinitely: "Until I stop it"
        case .halfHour: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .fourHours: "4 hours"
        case .time: "Until a chosen time…"
        case .appQuits: "Until an app quits…"
        }
    }
    func resolve(now: Date, date: Date, app: SessionApp?) -> KeepAwake.Until? {
        switch self {
        case .indefinitely: .indefinitely
        case .halfHour: .date(now.addingTimeInterval(1800))
        case .oneHour: .date(now.addingTimeInterval(3600))
        case .twoHours: .date(now.addingTimeInterval(7200))
        case .fourHours: .date(now.addingTimeInterval(14400))
        case .time: date.timeIntervalSinceReferenceDate.isFinite && date > now ? .date(date) : nil
        case .appQuits: app.map { .appQuits(pid: $0.pid, name: $0.name, launched: $0.launched) }
        }
    }
}

struct SessionApp: Equatable {
    let pid: pid_t
    let name: String
    let launched: Date?
    @MainActor static func running() -> [SessionApp] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map { .init(pid: $0.processIdentifier, name: $0.localizedName ?? "App", launched: $0.launchDate) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Native, session-only controls shared by Settings and the menu-bar panel.
@MainActor
final class SessionEndControls: NSStackView {
    let choice = NSPopUpButton()
    let date = NSDatePicker()
    let app = NSPopUpButton()
    let error = NSTextField(wrappingLabelWithString: "")
    private var apps: [SessionApp] = []
    var onLayoutChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6; detachesHiddenViews = true
        choice.addItems(withTitles: SessionEndChoice.allCases.map(\.title))
        choice.target = self; choice.action = #selector(changed)
        choice.setAccessibilityLabel("Keep Awake duration")
        date.datePickerStyle = .textFieldAndStepper
        date.datePickerElements = [.yearMonthDay, .hourMinute]
        date.dateValue = Date().addingTimeInterval(3600)
        date.setAccessibilityLabel("Keep Awake end time")
        app.setAccessibilityLabel("Keep awake until this app quits")
        let refresh = NSButton(title: "Refresh Apps", target: self, action: #selector(refreshApps))
        let row = NSStackView(views: [app, refresh]); row.spacing = 8
        row.identifier = .init("session-app-row")
        error.textColor = .systemOrange; error.font = .systemFont(ofSize: 11)
        addArrangedSubview(choice); addArrangedSubview(date); addArrangedSubview(row); addArrangedSubview(error)
        refreshApps(); changed()
    }
    required init?(coder: NSCoder) { nil }

    @objc func refreshApps() {
        let selected = apps.indices.contains(app.indexOfSelectedItem) ? apps[app.indexOfSelectedItem] : nil
        apps = SessionApp.running()
        app.removeAllItems(); app.addItems(withTitles: apps.map(\.name))
        if let selected, let index = apps.firstIndex(of: selected) { app.selectItem(at: index) }
    }
    @objc func changed() {
        let selected = SessionEndChoice(rawValue: choice.indexOfSelectedItem) ?? .indefinitely
        date.isHidden = selected != .time
        arrangedSubviews.first { $0.identifier?.rawValue == "session-app-row" }?.isHidden = selected != .appQuits
        error.stringValue = ""; error.isHidden = true
        onLayoutChange?()
    }
    func resolve(now: Date = Date()) -> KeepAwake.Until? {
        let selected = SessionEndChoice(rawValue: choice.indexOfSelectedItem) ?? .indefinitely
        let target = apps.indices.contains(app.indexOfSelectedItem) ? apps[app.indexOfSelectedItem] : nil
        let liveTarget = target.flatMap { SessionApp.running().contains($0) ? $0 : nil }
        let until = selected.resolve(now: now, date: date.dateValue, app: liveTarget)
        error.stringValue = until == nil ? (selected == .appQuits ? "Choose a running app, or refresh the list." : "Choose a future end time.") : ""
        error.isHidden = until != nil
        onLayoutChange?()
        return until
    }
}
