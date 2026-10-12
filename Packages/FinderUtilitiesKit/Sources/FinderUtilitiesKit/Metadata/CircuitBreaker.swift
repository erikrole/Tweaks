import Foundation

/// Per-volume breaker: `threshold` timeouts within `window` seconds open it for `cooldown` seconds.
public actor CircuitBreaker {
    private let threshold: Int
    private let window: TimeInterval
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private var timeouts: [String: [Date]] = [:]
    private var openUntil: [String: Date] = [:]

    public init(threshold: Int = 2, window: TimeInterval = 60, cooldown: TimeInterval = 300,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.threshold = threshold
        self.window = window
        self.cooldown = cooldown
        self.now = now
    }

    public func isOpen(_ key: String) -> Bool {
        guard let until = openUntil[key] else { return false }
        if now() >= until {
            openUntil[key] = nil
            timeouts[key] = nil
            return false
        }
        return true
    }

    public func recordTimeout(_ key: String) {
        let t = now()
        var list = (timeouts[key] ?? []).filter { t.timeIntervalSince($0) < window }
        list.append(t)
        timeouts[key] = list
        if list.count >= threshold { openUntil[key] = t.addingTimeInterval(cooldown) }
    }

    public func recordSuccess(_ key: String) {
        timeouts[key] = nil
    }
}
