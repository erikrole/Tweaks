import Darwin
import Foundation

/// Whether a file or volume is in use by any of your processes, via libproc. Tweaks
/// checks this before renaming, unzipping, unmounting or ejecting anything, so a file
/// that's still being written, or a drive a render is writing to, is left alone.
enum OpenFiles {
    /// True when some process has `path` open.
    static func isOpen(_ path: String) -> Bool {
        pidsUsing(path, flags: 0) > 0
    }

    /// True when some process has any file open on the volume mounted at `mountPoint`.
    static func volumeInUse(_ mountPoint: String) -> Bool {
        pidsUsing(mountPoint, flags: UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME)) > 0
    }

    /// Names of processes holding files on a volume. nil means an incomplete or
    /// failed read, which manual safe eject treats as a reason to leave it mounted.
    static func usersOfVolume(_ path: String) -> [String]? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let bytes = path.withCString {
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, $0, UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME), &pids, capacity)
        }
        guard bytes >= 0, bytes < capacity else { return nil }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map { pid in
            var name = [CChar](repeating: 0, count: 1024)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "PID \(pid)" }
            return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private static func pidsUsing(_ path: String, flags: UInt32) -> Int {
        var pids = [pid_t](repeating: 0, count: 512)
        let bytes = path.withCString { pointer in
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, pointer, flags, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return 0 }
        let own = getpid()
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 && $0 != own }.count
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
