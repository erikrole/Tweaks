import Foundation

public enum FileFlags {
    /// SF_DATALESS from <sys/stat.h>; not exported to Swift.
    private static let sfDataless: UInt32 = 0x4000_0000

    /// True when the file is a cloud placeholder whose bytes are not on disk. Uses lstat only.
    @Sendable public static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_flags & sfDataless != 0
    }
}

/// stat-level facts: size and dates. Safe on placeholders (no content read).
public struct FileAttributeProvider: MetadataProvider {
    public init() {}
    public func metadata(for url: URL) async throws -> MediaMetadata {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var m = MediaMetadata()
        m.fileSize = Int64(st.st_size)
        m.created = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
        m.modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return m
    }
}
