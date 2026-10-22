import Foundation
import Observation

struct RecentAction: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let message: String
}

/// Session-only history. Never writes filenames, clipboard contents or URLs to disk.
@MainActor
@Observable
final class RecentActions {
    private(set) var entries: [RecentAction] = []
    static let capacity = 100

    func record(_ message: String, at date: Date = Date()) {
        entries.insert(RecentAction(date: date, message: message), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    func clear() { entries.removeAll() }
}

/// A temporary override of execution, never of the saved feature switches.
@MainActor
@Observable
final class AutomationPause {
    private(set) var until: Date?
    var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        if let saved = defaults.object(forKey: "fileAutomationPausedUntil") as? Date, saved > now {
            until = saved
            armTimer()
        }
    }

    var isPaused: Bool { until != nil }

    func pause(for duration: TimeInterval, now: Date = Date()) {
        guard duration.isFinite, duration > 0 else { return }
        timer?.invalidate()
        until = now.addingTimeInterval(duration)
        defaults.set(until, forKey: "fileAutomationPausedUntil")
        armTimer()
        onChange?()
    }

    private func armTimer() {
        guard let until else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func resume() {
        guard until != nil else { return }
        timer?.invalidate()
        timer = nil
        until = nil
        defaults.removeObject(forKey: "fileAutomationPausedUntil")
        onChange?()
    }

    func expireIfNeeded(now: Date = Date()) {
        if let until, now >= until { resume() }
    }
}
