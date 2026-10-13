import Darwin
import Foundation

/// Jobs Keep Awake can wait for instead of a guessed time.
enum JobCondition: String, Codable, CaseIterable, Sendable {
    case render
    case downloads
    case upload
    case nasCopy

    init?(linkName: String) {
        switch linkName.lowercased() {
        case "render": self = .render
        case "downloads", "download": self = .downloads
        case "upload": self = .upload
        case "copy", "nas", "nascopy": self = .nasCopy
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .render: "Render finishes"
        case .downloads: "Downloads finish"
        case .upload: "Upload finishes"
        case .nasCopy: "NAS copy finishes"
        }
    }

    var untilPhrase: String {
        switch self {
        case .render: "the render finishes"
        case .downloads: "downloads finish"
        case .upload: "the upload finishes"
        case .nasCopy: "the NAS copy finishes"
        }
    }

    var shortLabel: String {
        switch self {
        case .render: "render"
        case .downloads: "downloads"
        case .upload: "upload"
        case .nasCopy: "copy"
        }
    }

    var symbol: String {
        switch self {
        case .render: "film"
        case .downloads: "arrow.down.circle"
        case .upload: "arrow.up.circle"
        case .nasCopy: "externaldrive.connected.to.line.below"
        }
    }

    var finishedMessage: String {
        switch self {
        case .render: "the render finished."
        case .downloads: "downloads finished."
        case .upload: "the upload finished."
        case .nasCopy: "the NAS copy finished."
        }
    }

    /// How long it must look finished before the session ends, so a pause between
    /// queue items or files doesn't end it early.
    var quietPeriod: TimeInterval {
        switch self {
        case .render: 180
        case .downloads: 60
        case .upload: 120
        case .nasCopy: 60
        }
    }
}

/// Judges whether a job is still going, sampled every check (about 15 s).
struct JobWatcher {
    private var quietSince: Date?
    private var startedAt: Date?
    private var sampler = CPUSampler()
    private var lastUpload: (bytes: UInt64, at: Date)?

    /// Bytes per second of upload that count as "still uploading".
    static let uploadThreshold: Double = 100_000

    mutating func isDone(_ job: JobCondition, now: Date) -> Bool {
        if startedAt == nil { startedAt = now }
        let busy = isBusy(job, now: now)
        return Self.decide(busy: busy, quietSince: &quietSince, startedAt: startedAt ?? now, now: now, quietPeriod: job.quietPeriod)
    }

    /// Done once the job has looked idle for `quietPeriod`. Measured from the start too,
    /// so a session started after the job already ended still finishes.
    static func decide(busy: Bool, quietSince: inout Date?, startedAt: Date, now: Date, quietPeriod: TimeInterval) -> Bool {
        if busy {
            quietSince = nil
            return false
        }
        let since = quietSince ?? now
        quietSince = since
        return now.timeIntervalSince(since) >= quietPeriod && now.timeIntervalSince(startedAt) >= quietPeriod
    }

    private mutating func isBusy(_ job: JobCondition, now: Date) -> Bool {
        switch job {
        case .render:
            let snap = sampler.sampleRenderers()
            return RenderKeepAwake.busyRenderer(in: snap.usage) != nil || snap.paths.contains(where: RenderProcesses.isRenderer)
        case .downloads:
            return Self.downloadsInProgress()
        case .upload:
            let bytes = Self.uploadedBytes()
            defer { lastUpload = (bytes, now) }
            guard let lastUpload else { return true } // no rate yet; assume busy
            let seconds = max(now.timeIntervalSince(lastUpload.at), 1)
            return counterRate(from: lastUpload.bytes, to: bytes, over: seconds) >= Self.uploadThreshold
        case .nasCopy:
            return NetworkShares.mounted().contains { OpenFiles.volumeInUse($0.mountPoint.path) }
        }
    }

    /// Any partial download in ~/Downloads (Chrome, Safari, Firefox, Edge, browsers' temp names).
    static func downloadsInProgress(in folder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { !DownloadsWatcher.isFinishedDownload(URL(filePath: $0)) }
    }

    /// Bytes sent since boot over physical interfaces (en*), so VPN tunnels don't count twice.
    static func uploadedBytes() -> UInt64 {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return 0 }
        defer { freeifaddrs(pointer) }
        var total: UInt64 = 0
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: item.pointee.ifa_name).hasPrefix("en"),
                  let data = item.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            total += UInt64(data.pointee.ifi_obytes)
        }
        return total
    }
}

/// Bytes per second between two cumulative counters; a counter that went backwards reads as zero.
func counterRate(from old: UInt64, to new: UInt64, over seconds: TimeInterval) -> Double {
    guard new >= old, seconds > 0 else { return 0 }
    return Double(new - old) / seconds
}
