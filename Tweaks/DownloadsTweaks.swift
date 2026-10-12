import AppKit
import Foundation

/// Watches ~/Downloads and tidies new files once they've finished downloading:
/// lowercases file extensions and hands calendar invites to Fantastical.
@MainActor
final class DownloadsWatcher {
    var lowercaseExtensions = false
    var openCalendarInvites = false
    var unzipArchives = false

    private let folder: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var seen: Set<String> = []
    /// Files waiting to settle: size and modification date when first seen unchanged.
    private var candidates: [String: (size: Int, modified: Date, since: Date)] = [:]
    private var pendingScan: DispatchWorkItem?

    /// How long a file must stay unchanged, and closed, before it's touched.
    static let settleTime: TimeInterval = 2

    static let fantasticalBundleID = "com.flexibits.fantastical2.mac"

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")) {
        self.folder = folder
    }

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        // Files already there are left alone; only new arrivals are touched.
        seen = Set(currentFiles().map(\.lastPathComponent))
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        let fd = descriptor
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        pendingScan?.cancel()
    }

    /// Waits a moment so a burst of writes becomes one scan.
    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func currentFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// A file is handled once it has kept the same size and modification date for
    /// `settleTime` across scans and no process has it open, so a slow copy from the NAS
    /// or an export still being written is never renamed or unzipped mid-write. Nothing
    /// here sleeps on the main thread; unsettled files just trigger another scan.
    private func scan() {
        let files = currentFiles()
        let names = Set(files.map(\.lastPathComponent))
        // Forget files that are gone, so a re-download with the same name is handled.
        seen.formIntersection(names)
        candidates = candidates.filter { names.contains($0.key) }

        let now = Date()
        var needsAnotherScan = false
        for url in files where !seen.contains(url.lastPathComponent) {
            guard Self.isFinishedDownload(url) else { continue }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? -1
            let modified = values?.contentModificationDate ?? .distantPast
            if let candidate = candidates[name], candidate.size == size, candidate.modified == modified {
                if now.timeIntervalSince(candidate.since) >= Self.settleTime, !OpenFiles.isOpen(url.path) {
                    candidates[name] = nil
                    seen.insert(name)
                    handle(url)
                } else {
                    needsAnotherScan = true
                }
            } else {
                candidates[name] = (size, modified, now)
                needsAnotherScan = true
            }
        }
        if needsAnotherScan { scheduleScan() }
    }

    private func handle(_ url: URL) {
        var url = url
        if lowercaseExtensions, let renamed = Self.lowercasedExtension(of: url) {
            if Self.moveCaseOnly(from: url, to: renamed) {
                seen.insert(renamed.lastPathComponent)
                url = renamed
            }
        }
        if openCalendarInvites, url.pathExtension.lowercased() == "ics" {
            openInvite(url)
        }
        if unzipArchives, url.pathExtension.lowercased() == "zip" {
            Task { await Self.unzip(url) }
        }
    }

    // MARK: - Calendar invites

    private func openInvite(_ url: URL) {
        guard let fantastical = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.fantasticalBundleID),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let cleaned = Self.removingAlarms(from: text)
        let copy = FileManager.default.temporaryDirectory.appending(path: url.lastPathComponent)
        do {
            try cleaned.write(to: copy, atomically: true, encoding: .utf8)
        } catch { return }
        // Fantastical reads the copy as it opens; tidy it up a minute later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: copy) }
        NSWorkspace.shared.open([copy], withApplicationAt: fantastical, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    /// Drops every VALARM block so an invite doesn't bring its sender's reminders along.
    static func removingAlarms(from ics: String) -> String {
        var output: [Substring] = []
        var depth = 0
        // Split on any line break: invites use CRLF, which Swift treats as one Character,
        // so splitting on "\n" alone would see a single line and strip nothing.
        for line in ics.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmed == "BEGIN:VALARM" { depth += 1; continue }
            if trimmed == "END:VALARM", depth > 0 { depth -= 1; continue }
            if depth == 0 { output.append(line) }
        }
        return output.joined(separator: "\r\n")
    }

    // MARK: - Zip archives

    /// Extracts next to the archive like Archive Utility (a single item comes out as is,
    /// several land in a folder named after the zip), then trashes the zip.
    static func unzip(_ archive: URL) async {
        // If Safari or a double-click already handed it to Archive Utility, leave it be.
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.archiveutility" }) {
            return
        }
        let folder = archive.deletingLastPathComponent()
        let staging = FileManager.default.temporaryDirectory.appending(path: "tweaks-unzip-\(UUID().uuidString)")
        let succeeded = await Task.detached { () -> Bool in
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, staging.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        defer { try? FileManager.default.removeItem(at: staging) }
        guard succeeded else { return }

        // Refuse archives with links pointing outside themselves; keep the zip instead.
        guard !containsEscapingSymlink(in: staging) else { return }
        try? FileManager.default.removeItem(at: staging.appending(path: "__MACOSX"))
        try? FileManager.default.removeItem(at: staging.appending(path: ".DS_Store"))
        let items = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty else { return }
        do {
            // One move into Downloads, so a failure never leaves a half-filled folder.
            if items.count == 1 {
                try FileManager.default.moveItem(at: items[0], to: uniqueURL(for: items[0].lastPathComponent, in: folder))
            } else {
                try FileManager.default.moveItem(at: staging, to: uniqueURL(for: archive.deletingPathExtension().lastPathComponent, in: folder))
            }
            try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
        } catch {
            // Leave the zip in place if anything went wrong.
        }
    }

    /// True if any symbolic link inside `root` resolves to somewhere outside it.
    static func containsEscapingSymlink(in root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = url.resolvingSymlinksInPath().standardizedFileURL.path
            if !(target == base || target.hasPrefix(base + "/")) { return true }
        }
        return false
    }

    /// "Clip.mov" → "Clip 2.mov" when the name is taken.
    static func uniqueURL(for name: String, in folder: URL) -> URL {
        let candidate = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            let next = folder.appending(path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return folder.appending(path: "\(base) \(UUID().uuidString.prefix(6))\(ext.isEmpty ? "" : ".\(ext)")")
    }

    // MARK: - Extensions

    nonisolated static func isFinishedDownload(_ url: URL) -> Bool {
        let inProgress: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "tmp"]
        return !inProgress.contains(url.pathExtension.lowercased())
    }

    /// "IMG_0001.JPG" → "IMG_0001.jpg"; nil when there's nothing to change.
    static func lowercasedExtension(of url: URL) -> URL? {
        let ext = url.pathExtension
        guard !ext.isEmpty, ext != ext.lowercased(), !url.hasDirectoryPath,
              (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
        else { return nil }
        return url.deletingPathExtension().appendingPathExtension(ext.lowercased())
    }

    /// Case-only rename. rename(2) does this atomically on APFS; the two-step fallback
    /// (via a hidden temporary name) is only for volumes where it refuses.
    static func moveCaseOnly(from source: URL, to destination: URL) -> Bool {
        if rename(source.path, destination.path) == 0 { return true }
        let fileManager = FileManager.default
        let temporary = source.deletingLastPathComponent().appending(path: ".tweaks-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: source, to: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: destination)
                return true
            } catch {
                try? fileManager.moveItem(at: temporary, to: source)
                return false
            }
        } catch {
            return false
        }
    }
}
