import AppKit
import CryptoKit
import Observation

struct DuplicateMatch: Identifiable, Sendable {
    var id: String { newFile.path }
    let newFile: URL
    let existingFile: URL
    let newVersion: FileVersion
    let existingVersion: FileVersion
    let bytes: Int64
}

enum DuplicateFiles {
    static func find(for file: URL, in folder: URL, shouldContinue: () -> Bool = { true }) -> DuplicateMatch? {
        guard shouldContinue(), !hasResourceFork(file), let version = FileVersion.read(file), version.byteCount > 0,
              let names = DownloadDirectory.names(in: folder) else { return nil }
        var newDigest: Data?
        for name in names.sorted() where !name.hasPrefix(".") && DownloadsWatcher.isFinishedDownload(named: name) {
            guard shouldContinue(), version.matches(file) else { return nil }
            let other = folder.appendingPathComponent(name, isDirectory: false)
            guard other != file, let candidate = FileVersion.read(other), candidate.byteCount == version.byteCount,
                  !candidate.isSameFile(as: version), !hasResourceFork(other) else { continue }
            do {
                if newDigest == nil { newDigest = try digest(file, shouldContinue: shouldContinue) }
                guard try digest(other, shouldContinue: shouldContinue) == newDigest,
                      version.matches(file), candidate.matches(other),
                      !OpenFiles.isOpen(other.path), candidate.matches(other), shouldContinue() else { continue }
                return DuplicateMatch(newFile: file, existingFile: other, newVersion: version,
                                      existingVersion: candidate, bytes: version.byteCount)
            } catch { return nil }
        }
        return nil
    }

    static func hasResourceFork(_ file: URL) -> Bool {
        let bytes = getxattr(file.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        return bytes >= 0 ? bytes > 0 : errno != ENOATTR
    }

    static func digest(_ file: URL, shouldContinue: () -> Bool = { true }) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            guard shouldContinue() else { throw CancellationError() }
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return Data(hash.finalize())
    }

    /// Check both identities and every byte again immediately before the user-approved trash.
    static func validate(_ match: DuplicateMatch) throws -> Bool {
        guard !hasResourceFork(match.newFile), !hasResourceFork(match.existingFile),
              match.newVersion.matches(match.newFile), match.existingVersion.matches(match.existingFile),
              !OpenFiles.isOpen(match.newFile.path), !OpenFiles.isOpen(match.existingFile.path) else { return false }
        let first = try FileHandle(forReadingFrom: match.newFile)
        defer { try? first.close() }
        let second = try FileHandle(forReadingFrom: match.existingFile)
        defer { try? second.close() }
        while true {
            let a = try first.read(upToCount: 1_048_576) ?? Data()
            let b = try second.read(upToCount: 1_048_576) ?? Data()
            guard a == b else { return false }
            if a.isEmpty { break }
        }
        return !hasResourceFork(match.newFile) && !hasResourceFork(match.existingFile)
            && match.newVersion.matches(match.newFile) && match.existingVersion.matches(match.existingFile)
    }
}

@MainActor
@Observable
final class DuplicateReview {
    private(set) var matches: [DuplicateMatch] = []
    private(set) var busy = false
    private(set) var status = "New duplicates appear here. Nothing is trashed automatically."

    func add(_ match: DuplicateMatch) {
        guard !matches.contains(where: { $0.id == match.id }), matches.count < 100 else { return }
        matches.append(match)
        status = "\(matches.count) duplicate download(s) waiting for review."
        Notifier.post(title: "Duplicate download found", body: "\(match.newFile.lastPathComponent) matches an existing file. Review it in Tweaks.")
    }

    func keep(_ match: DuplicateMatch) { matches.removeAll { $0.id == match.id } }
    func clear() { matches = [] }

    func trash(_ match: DuplicateMatch) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let removed = try await FileWork.run {
                guard try DuplicateFiles.validate(match) else { return false }
                try FileManager.default.trashItem(at: match.newFile, resultingItemURL: nil)
                return true
            }
            status = removed ? "Moved \(match.newFile.lastPathComponent) to the Trash. The existing file is unchanged."
                : "A file changed or is in use. Both files were left alone."
            keep(match)
        } catch { status = "Could not trash the new copy: \(error.localizedDescription)" }
    }
}
