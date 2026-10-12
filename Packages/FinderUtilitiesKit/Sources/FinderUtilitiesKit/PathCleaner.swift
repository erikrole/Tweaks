import Foundation

/// Turns Finder paths into the short, shareable form Erik pastes into chats and tickets.
///
/// Pure string work: it never touches the disk, so it is safe on dead network shares and
/// cloud placeholders.
public struct PathCleaner: Sendable {
    /// Path component that marks the end of the volume scaffolding, e.g. "shares" in
    /// `/Volumes/users/shares/Media/Foo.mov`. Empty means only the volume prefix is stripped.
    public var marker: String

    public init(marker: String = "shares") {
        self.marker = marker
    }

    /// Cleans one POSIX path.
    public func clean(path: String) -> String {
        let normalized = Self.normalize(path)
        var parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if let cloud = Self.cloudParts(in: parts) {
            parts = cloud
        } else if parts.first == "Volumes" {
            parts.removeFirst()
            if !parts.isEmpty { parts.removeFirst() } // volume name
            if !marker.isEmpty,
               let m = parts.first,
               Self.fold(m) == Self.fold(marker) {
                parts.removeFirst()
            }
        } else {
            // Local and iCloud paths are returned as the full POSIX path.
            return normalized
        }
        return parts.joined(separator: "/")
    }

    /// Cleans several URLs, one per line, preserving selection order.
    public func clean(_ urls: [URL]) -> String {
        urls.map { clean(path: $0.path(percentEncoded: false)) }.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Drops the Data-volume firmlink prefix and `/private` aliases, and any trailing slash.
    static func normalize(_ path: String) -> String {
        var p = path
        let data = "/System/Volumes/Data"
        if p.hasPrefix(data + "/") { p.removeFirst(data.count) }
        for alias in ["/private/var", "/private/tmp", "/private/etc"] where p == alias || p.hasPrefix(alias + "/") {
            p.removeFirst("/private".count)
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Shortens modern File Provider roots under ~/Library/CloudStorage, or returns nil.
    /// Box-Box/Projects -> Box/Projects; GoogleDrive-x@y.com/My Drive/A -> My Drive/A.
    static func cloudParts(in parts: [String]) -> [String]? {
        guard let cs = parts.firstIndex(of: "CloudStorage"),
              cs > 0, parts[cs - 1] == "Library",
              cs + 1 < parts.count else { return nil }
        let root = parts[cs + 1]
        let rest = Array(parts[(cs + 2)...])
        if root.hasPrefix("GoogleDrive-") { return rest }
        if root == "Box-Box" { return ["Box"] + rest }
        return nil
    }
}
