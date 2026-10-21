import Darwin
import Foundation
import os

/// Whether a file or volume is in use by any of your processes, via libproc. Tweaks
/// checks this before renaming, unzipping, unmounting or ejecting anything, so a file
/// that's still being written, or a drive a render is writing to, is left alone.
enum OpenFiles {
    /// True when some process has `path` open.
    /// Fails safe: a lookup that doesn't answer in time counts as open, so nothing is
    /// renamed, moved or trashed.
    static func isOpen(_ path: String) -> Bool {
        bounded(fallback: true) { pidsUsing(path, flags: 0) > 0 }
    }

    /// True when some process has any file open on the volume mounted at `mountPoint`.
    /// Fails safe: a lookup that doesn't answer in time counts as in use, so nothing is unmounted.
    static func volumeInUse(_ mountPoint: String) -> Bool {
        bounded(fallback: true) { pidsUsing(mountPoint, flags: UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME)) > 0 }
    }

    /// Names of processes holding files on a volume. nil means an incomplete or
    /// failed read, which manual safe eject treats as a reason to leave it mounted.
    static func usersOfVolume(_ path: String) -> [String]? {
        bounded(fallback: nil) { listUsers(path) }
    }

    /// Every lookup runs off the caller's thread and gives up after `lookupTimeout`; at
    /// most two stuck lookups are left running, after which answers fall back at once.
    static let lookupTimeout: TimeInterval = 5
    private static let lookupQueue = DispatchQueue(label: "Tweaks.open-files", qos: .utility, attributes: .concurrent)
    private static let stuck = OSAllocatedUnfairLock(initialState: 0)

    static func bounded<T: Sendable>(fallback: T, timeout: TimeInterval = lookupTimeout,
                                     _ work: @escaping @Sendable () -> T) -> T {
        guard stuck.withLock({ count -> Bool in
            guard count < 2 else { return false }
            count += 1
            return true
        }) else { return fallback }
        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        lookupQueue.async {
            let value = work()
            result.withLock { $0 = value }
            stuck.withLock { $0 -= 1 }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return fallback }
        return result.withLock { $0 } ?? fallback
    }

    /// Processes whose file table can block an inspecting process indefinitely.
    /// proc_listpidspath walks every process and hung on a Virtualization.framework VM,
    /// so the scan below matches by device and inode and skips these.
    static func skipsInspection(_ name: String) -> Bool {
        name.hasPrefix("com.apple.Virtualization")
    }

    private static func name(of pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "PID \(pid)" }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// PIDs (other than Tweaks) with an open file on `path`'s volume (`volume`) or on
    /// `path` itself. nil when the target can't be read or the process list is incomplete.
    private static func scan(_ path: String, volume: Bool) -> [pid_t]? {
        var target = stat()
        guard stat(path, &target) == 0 else { return volume ? nil : [] }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard listed > 0, listed < pids.count else { return nil }
        let own = getpid()
        var users: [pid_t] = []
        for pid in pids.prefix(listed) where pid > 0 && pid != own {
            guard !skipsInspection(name(of: pid)) else { continue }
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue } // gone, or not ours to inspect
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard got > 0 else { continue }
            let uses = fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size).contains { fd in
                guard fd.proc_fdtype == PROX_FDTYPE_VNODE else { return false }
                var info = vnode_fdinfo()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info,
                                     Int32(MemoryLayout<vnode_fdinfo>.size)) == MemoryLayout<vnode_fdinfo>.size else { return false }
                let stat = info.pvi.vi_stat
                return UInt64(bitPattern: Int64(stat.vst_dev)) == UInt64(bitPattern: Int64(target.st_dev))
                    && (volume || stat.vst_ino == target.st_ino)
            }
            if uses { users.append(pid) }
        }
        return users
    }

    private static func listUsers(_ path: String) -> [String]? {
        scan(path, volume: true)?.map(name(of:))
    }

    private static func pidsUsing(_ path: String, flags: UInt32) -> Int {
        let volume = flags & UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME) != 0
        // An incomplete scan counts as in use: the callers then leave things alone.
        return scan(path, volume: volume)?.count ?? 1
    }
}

/// Whether a render process (aerender or After Effects' render engine) is running at all,
/// busy or not. Sleep-time unmounts and ejects are skipped while one exists.
enum RenderProcesses {
    static func anyRunning() -> Bool {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if isRenderer(String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) { return true }
        }
        return false
    }

    static func isRenderer(_ path: String) -> Bool {
        path.hasSuffix("/aerender") || path.hasSuffix("/aerendercore")
            || path.contains("/Adobe After Effects Render Engine")
    }
}
