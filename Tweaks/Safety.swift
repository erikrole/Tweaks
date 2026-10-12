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
            if isRenderer(String(cString: path)) { return true }
        }
        return false
    }

    static func isRenderer(_ path: String) -> Bool {
        path.hasSuffix("/aerender") || path.hasSuffix("/aerendercore")
            || path.contains("/Adobe After Effects Render Engine")
    }
}
