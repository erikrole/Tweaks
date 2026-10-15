import Darwin
import Foundation

/// Blocking filesystem work runs on a serial utility queue, away from AppKit and
/// Swift's cooperative executor. Serial execution also bounds archive extraction.
enum FileWork {
    static let queue = DispatchQueue(label: "com.erole.Tweaks.file-work", qos: .utility)

    static func run<T: Sendable>(on queue: DispatchQueue = queue,
                                _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

/// A queued path may have been replaced or resumed since settling. Retain both
/// identity and timestamps, and leave changed files untouched.
struct FileVersion: Equatable, Sendable {
    private let device: dev_t
    private let inode: ino_t
    private let size: off_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    var byteCount: Int64 { Int64(size) }
    func isSameFile(as other: FileVersion) -> Bool { device == other.device && inode == other.inode }

    static func read(_ url: URL) -> FileVersion? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileVersion(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                           modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                           changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    func matches(_ url: URL) -> Bool { Self.read(url) == self }

    /// A case-only rename can update ctime; the inode and contents must still match.
    func sameContents(as other: FileVersion) -> Bool {
        device == other.device && inode == other.inode && size == other.size
            && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}
