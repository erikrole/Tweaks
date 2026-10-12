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
    private var pendingScan: DispatchWorkItem?

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
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func scan() {
        for url in currentFiles() where !seen.contains(url.lastPathComponent) {
            guard Self.isFinishedDownload(url) else { continue }
            guard isStable(url) else {
                scheduleScan()
                continue
            }
            seen.insert(url.lastPathComponent)
            handle(url)
        }
    }

    /// Size unchanged across a short pause, so a still-copying file isn't touched.
    private func isStable(_ url: URL) -> Bool {
        let first = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        Thread.sleep(forTimeInterval: 0.2)
        let second = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return first == second
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

        let items = ((try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        guard !items.isEmpty else { return }
        do {
            if items.count == 1 {
                try FileManager.default.moveItem(at: items[0], to: uniqueURL(for: items[0].lastPathComponent, in: folder))
            } else {
                let destination = uniqueURL(for: archive.deletingPathExtension().lastPathComponent, in: folder)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                for item in items {
                    try FileManager.default.moveItem(at: item, to: destination.appending(path: item.lastPathComponent))
                }
            }
            try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
        } catch {
            // Leave the zip in place if anything went wrong.
        }
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

    static func isFinishedDownload(_ url: URL) -> Bool {
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

    /// Renames via a temporary name, since a case-only rename fails on a
    /// case-insensitive volume when done in one step.
    static func moveCaseOnly(from source: URL, to destination: URL) -> Bool {
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
