import Foundation

/// Decides which directory roots the Finder Sync extension should monitor. Pure and I/O-free:
/// the caller supplies the mount table and the CloudStorage listing.
public enum ScopeRoots {
    /// `/` alone does not reliably cover network volumes, so each mounted volume root under /Volumes
    /// and each ~/Library/CloudStorage provider folder is added explicitly.
    public static func compute(mountPoints: [String], cloudStorageEntries: [String], home: String) -> [String] {
        var roots: Set<String> = ["/"]
        for mp in mountPoints where mp.hasPrefix("/Volumes/") && mp.count > "/Volumes/".count {
            roots.insert(trim(mp))
        }
        let cloud = home + "/Library/CloudStorage"
        for name in cloudStorageEntries where !name.hasPrefix(".") {
            roots.insert(cloud + "/" + name)
        }
        roots.insert(home + "/Library/Mobile Documents")
        return roots.sorted()
    }

    /// True when the set differs, so `directoryURLs` is only reassigned on a real change.
    public static func hasChanged(old: [String], new: [String]) -> Bool {
        Set(old) != Set(new)
    }

    private static func trim(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
