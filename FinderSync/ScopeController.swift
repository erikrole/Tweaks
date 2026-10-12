import AppKit
import FinderSync
import FinderUtilitiesKit
import OSLog

private typealias FSStat = statfs
private let log = Logger(subsystem: "com.erole.Tweaks.FinderSync", category: "scope")

/// Keeps `directoryURLs` in step with mounted volumes and cloud folders. Mount table comes from
/// `getfsstat(MNT_NOWAIT)`, which never blocks on a hung server; changes are debounced 300 ms.
@MainActor
final class ScopeController {
    static let shared = ScopeController()
    private var current: [String] = []
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        apply()
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    private func apply() {
        let roots = ScopeRoots.compute(mountPoints: Self.mountPoints(),
                                       cloudStorageEntries: Self.cloudStorageEntries(),
                                       home: Self.realHome())
        guard ScopeRoots.hasChanged(old: current, new: roots) else { return }
        current = roots
        FIFinderSyncController.default().directoryURLs = Set(roots.map { URL(fileURLWithPath: $0) })
        log.info("scope updated: \(roots.count, privacy: .public) roots")
    }

    /// Real home from the password database; NSHomeDirectory is the sandbox container.
    private static func realHome() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private static func mountPoints() -> [String] {
        let n = getfsstat(nil, 0, MNT_NOWAIT)
        guard n > 0 else { return [] }
        var buf = [FSStat](repeating: FSStat(), count: Int(n))
        let size = Int32(MemoryLayout<FSStat>.stride * Int(n))
        let got = getfsstat(&buf, size, MNT_NOWAIT)
        guard got > 0 else { return [] }
        return buf.prefix(Int(got)).map { fs in
            withUnsafePointer(to: fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }

    /// Directory listing only; never opens files, so it cannot materialize cloud content.
    private static func cloudStorageEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: realHome() + "/Library/CloudStorage")) ?? []
    }
}
