import Foundation

/// What `menu(for:)` sees for one file. Reading it never does I/O.
public enum MetadataState: Sendable, Equatable {
    case loading
    case ready(MediaMetadata)
    case unavailable(String)
}

/// Background prefetch plus an in-memory cache. `state(for:)` is synchronous and lock-only,
/// so the Finder Sync menu stays I/O-free; the first lookup reports `.loading`.
public final class MetadataService: @unchecked Sendable {
    public struct Timeouts: Sendable {
        public var local: TimeInterval
        public var network: TimeInterval
        public init(local: TimeInterval = 2, network: TimeInterval = 4) {
            self.local = local
            self.network = network
        }
    }

    private let providers: [any MetadataProvider]
    private let datalessCheck: @Sendable (URL) -> Bool
    private let breaker: CircuitBreaker
    private let timeouts: Timeouts
    private let maxPerVolume: Int
    private let lock = NSLock()
    private var cache: [String: MetadataState] = [:]
    private var order: [String] = []
    private var inFlight: [String: Int] = [:]
    private let capacity: Int

    public init(providers: [any MetadataProvider],
                datalessCheck: @escaping @Sendable (URL) -> Bool = FileFlags.isDataless,
                breaker: CircuitBreaker = CircuitBreaker(),
                timeouts: Timeouts = Timeouts(),
                maxPerVolume: Int = 4,
                capacity: Int = 500) {
        self.providers = providers
        self.datalessCheck = datalessCheck
        self.breaker = breaker
        self.timeouts = timeouts
        self.maxPerVolume = maxPerVolume
        self.capacity = capacity
    }

    /// Cached state, or `.loading` if nothing is known yet. Never blocks on I/O.
    public func state(for url: URL) -> MetadataState {
        lock.lock(); defer { lock.unlock() }
        return cache[url.path] ?? .loading
    }

    /// Starts a background read and immediately returns the cached state. A cold menu
    /// shows Loading; reopening it shows the result without ever waiting on a share.
    public func menuState(for url: URL) -> MetadataState {
        prefetch([url])
        return state(for: url)
    }

    /// Starts background reads for uncached files. Returns immediately.
    public func prefetch(_ urls: [URL]) {
        for url in urls {
            let path = url.path
            let vol = VolumeInfo.classify(path: path)
            lock.lock()
            let known = cache[path] != nil
            let busy = (inFlight[vol.key] ?? 0) >= maxPerVolume
            if !known && !busy {
                store(path, .loading)
                inFlight[vol.key, default: 0] += 1
            }
            lock.unlock()
            guard !known && !busy else { continue }
            Task.detached { [self] in
                let result = await load(url, volume: vol)
                finish(path, vol.key, result)
            }
        }
    }

    /// Forgets cached results (call when files may have changed).
    public func invalidate() {
        lock.lock(); cache.removeAll(); order.removeAll(); lock.unlock()
    }

    /// Awaitable variant for tests and the host app.
    public func load(_ url: URL, volume: VolumeInfo? = nil) async -> MetadataState {
        let vol = volume ?? VolumeInfo.classify(path: url.path)
        if await breaker.isOpen(vol.key) { return .unavailable("Volume not responding; retrying later") }

        let timeout = vol.kind == .local ? timeouts.local : timeouts.network
        let datalessCheck = self.datalessCheck
        let providers = self.providers
        do {
            let meta = try await withDeadline(seconds: timeout) {
                var out = MediaMetadata()
                if datalessCheck(url) {
                    // Never materialize cloud placeholders: only the stat-level provider runs.
                    out.isDataless = true
                    if let first = providers.first { out.merge(try await first.metadata(for: url)) }
                    out.isDataless = true
                    return out
                }
                for p in providers { out.merge(try await p.metadata(for: url)) }
                return out
            }
            await breaker.recordSuccess(vol.key)
            return .ready(meta)
        } catch MetadataFailure.timedOut {
            await breaker.recordTimeout(vol.key)
            return .unavailable("Timed out")
        } catch {
            return .unavailable("Unreadable")
        }
    }

    private func finish(_ path: String, _ volumeKey: String, _ state: MetadataState) {
        lock.lock(); defer { lock.unlock() }
        store(path, state)
        inFlight[volumeKey, default: 1] -= 1
    }

    private func store(_ path: String, _ state: MetadataState) {
        if cache[path] == nil { order.append(path) }
        cache[path] = state
        while order.count > capacity { cache[order.removeFirst()] = nil }
    }
}
