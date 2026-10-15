import AppKit
import Foundation

/// Main-actor facade: settings and Workspace calls only. Each start owns a fresh
/// session; directory state and blocking file operations belong to its worker queue.
@MainActor
final class DownloadsWatcher {
    var lowercaseExtensions = false { didSet { updateOptions() } }
    var openCalendarInvites = false { didSet { updateOptions() } }
    var unzipArchives = false { didSet { updateOptions() } }
    var detectDuplicates = false { didSet { updateOptions() } }
    var onDuplicate: (@MainActor @Sendable (DuplicateMatch) -> Void)?

    private let folder: URL
    private let queue: DispatchQueue?
    private let fileIsOpen: @Sendable (String) -> Bool
    private var session: DownloadSession?
    nonisolated static let settleTime: TimeInterval = 2
    nonisolated static let fantasticalBundleID = "com.flexibits.fantastical2.mac"

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads"),
         queue: DispatchQueue? = nil,
         fileIsOpen: @escaping @Sendable (String) -> Bool = OpenFiles.isOpen) {
        self.folder = folder
        self.queue = queue
        self.fileIsOpen = fileIsOpen
    }

    /// Startup is asynchronous: watching begins after the existing-file snapshot.
    var isRunning: Bool { session?.isReady == true }

    private var options: DownloadSession.Options {
        .init(lowercase: lowercaseExtensions, invites: openCalendarInvites, archives: unzipArchives, duplicates: detectDuplicates)
    }

    private func updateOptions() { session?.update(options) }

    func start() {
        guard session == nil else { return }
        // A busy archive or cancelled old scan must not delay the next session's
        // initial snapshot. Discovery and extraction use independent serial queues.
        let worker = DownloadSession(folder: folder,
                                     queue: queue ?? DispatchQueue(label: "com.erole.Tweaks.downloads.\(UUID().uuidString)", qos: .utility),
                                     options: options, fileIsOpen: fileIsOpen, onDuplicate: onDuplicate)
        session = worker
        worker.start { [weak self, weak worker] in
            guard let self, let worker, self.session === worker else { return }
            self.session = nil
        }
    }

    func stop() {
        session?.cancel()
        session = nil
    }

    deinit { session?.cancel() }

    /// Allows deterministic callers to wait for the initial existing-file snapshot.
    func waitUntilReady() async { await session?.waitUntilReady() }

    func scan(now: Date = Date()) async { await session?.scan(now: now) }

    /// Drops every VALARM block so an invite doesn't bring its sender's reminders along.
    nonisolated static func removingAlarms(from ics: String) -> String {
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
    static func unzip(_ archive: URL, expectedVersion: FileVersion? = nil,
                      shouldContinue: @escaping @Sendable () -> Bool = { true },
                      onDeferred: @escaping @Sendable () -> Void = {}) async {
        // Workspace interaction stays on the main actor; all archive I/O stays off it.
        guard shouldContinue(),
              !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.archiveutility" })
        else { return }
        try? await FileWork.run {
            extractArchive(archive, expectedVersion: expectedVersion, shouldContinue: shouldContinue, onDeferred: onDeferred)
        }
    }

    nonisolated private static func extractArchive(_ archive: URL, expectedVersion: FileVersion?,
                                                  shouldContinue: () -> Bool, onDeferred: () -> Void) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard shouldContinue() else { return }
        guard let version = expectedVersion ?? FileVersion.read(archive),
              version.matches(archive), !OpenFiles.isOpen(archive.path), version.matches(archive)
        else { onDeferred(); return }
        let folder = archive.deletingLastPathComponent()
        let staging = FileManager.default.temporaryDirectory.appending(path: "tweaks-unzip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { return }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, staging.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0, shouldContinue() else { return }
        guard version.matches(archive) else { onDeferred(); return }

        // Refuse unreadable trees and links escaping the extraction root.
        guard !containsEscapingSymlink(in: staging) else { return }
        try? FileManager.default.removeItem(at: staging.appending(path: "__MACOSX"))
        try? FileManager.default.removeItem(at: staging.appending(path: ".DS_Store"))
        guard let items = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil),
              !items.isEmpty, shouldContinue()
        else { return }
        guard version.matches(archive) else { onDeferred(); return }
        do {
            // Once the move starts, finish this transaction even if settings change.
            if items.count == 1 {
                try FileManager.default.moveItem(at: items[0], to: uniqueURL(for: items[0].lastPathComponent, in: folder))
            } else {
                try FileManager.default.moveItem(at: staging, to: uniqueURL(for: archive.deletingPathExtension().lastPathComponent, in: folder))
            }
            if version.matches(archive) {
                try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            } else { onDeferred() }
        } catch {
            // Keep the original archive on failure. moveItem never replaces a destination.
        }
    }

    /// True if any symbolic link inside `root` resolves to somewhere outside it.
    nonisolated static func containsEscapingSymlink(in root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, _ in
            failed = true
            return false
        }) else { return true }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return true }
            guard values.isSymbolicLink == true else { continue }
            let target = url.resolvingSymlinksInPath().standardizedFileURL.path
            if !(target == base || target.hasPrefix(base + "/")) { return true }
        }
        return failed
    }

    /// "Clip.mov" → "Clip 2.mov" when the name is taken.
    nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
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
        isFinishedDownload(named: url.lastPathComponent)
    }

    nonisolated private static let inProgressExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "opdownload", "tmp",
    ]

    /// Names from a directory listing need no URL allocation or filesystem lookup.
    nonisolated static func isFinishedDownload(named name: String) -> Bool {
        !inProgressExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// "IMG_0001.JPG" → "IMG_0001.jpg"; nil when there's nothing to change.
    nonisolated static func lowercasedExtension(of url: URL) -> URL? {
        let ext = url.pathExtension
        guard !ext.isEmpty, ext != ext.lowercased(), !url.hasDirectoryPath,
              (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
        else { return nil }
        return url.deletingPathExtension().appendingPathExtension(ext.lowercased())
    }

    /// Atomic case-only rename that cannot replace an existing distinct directory entry.
    /// APFS permits the case change with RENAME_EXCL. On unsupported volumes leave the
    /// original alone; a check followed by ordinary rename would still race other writers.
    nonisolated static func moveCaseOnly(from source: URL, to destination: URL) -> Bool {
        renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0
    }
}


/// Mutable directory state is confined to `queue`. Only options/cancellation cross
/// queues, protected by `lock`; no filesystem operation runs while that lock is held.
private final class DownloadSession: @unchecked Sendable {
    struct Options: Sendable {
        var lowercase: Bool
        var invites: Bool
        var archives: Bool
        var duplicates: Bool
    }

    private let folder: URL
    private let queue: DispatchQueue
    private let fileIsOpen: @Sendable (String) -> Bool
    private let onDuplicate: (@MainActor @Sendable (DuplicateMatch) -> Void)?
    private let lock = NSLock()
    private var configuration: Options?
    private var ready = false
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: DispatchWorkItem?
    private var seen: Set<String> = []
    private var candidates: [String: (version: FileVersion, since: Date)] = [:]

    init(folder: URL, queue: DispatchQueue, options: Options,
         fileIsOpen: @escaping @Sendable (String) -> Bool,
         onDuplicate: (@MainActor @Sendable (DuplicateMatch) -> Void)?) {
        self.onDuplicate = onDuplicate
        self.folder = folder
        self.queue = queue
        self.configuration = options
        self.fileIsOpen = fileIsOpen
    }

    private var options: Options? { lock.withLock { configuration } }
    var isReady: Bool { lock.withLock { ready && configuration != nil } }
    func update(_ options: Options) { lock.withLock { if configuration != nil { configuration = options } } }

    func cancel() {
        lock.withLock { configuration = nil; ready = false }
        queue.async { self.tearDown() }
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        pendingScan?.cancel()
        pendingScan = nil
        candidates.removeAll()
    }

    func start(onFailure: @escaping @Sendable @MainActor () -> Void) {
        queue.async { [self] in
            guard self.options != nil else { return }
            let descriptor = open(self.folder.path, O_EVTONLY)
            guard descriptor >= 0 else {
                Task { @MainActor in onFailure() }
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: self.queue)
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in self?.scheduleScan() }
            self.source = source
            // Open the event source before the snapshot so arrivals afterwards are seen.
            let names = self.currentNames()
            source.resume()
            guard let names, self.options != nil else {
                self.tearDown()
                Task { @MainActor in onFailure() }
                return
            }
            self.seen = Set(names)
            self.lock.withLock { self.ready = self.configuration != nil }
        }
    }

    func waitUntilReady() async { try? await FileWork.run(on: queue) {} }
    func scan(now: Date) async { try? await FileWork.run(on: queue) { self.scanOnQueue(now: now) } }

    private func scheduleScan() {
        guard options != nil else { return }
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanOnQueue(now: Date()) }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func currentNames() -> [String]? {
        DownloadDirectory.names(in: folder)?.filter { !$0.hasPrefix(".") }
    }

    private func scanOnQueue(now: Date) {
        dispatchPrecondition(condition: .onQueue(queue))
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard options != nil, source != nil, let listed = currentNames() else { return }
        let names = Set(listed)
        seen.formIntersection(names)
        candidates = candidates.filter { names.contains($0.key) }
        var needsAnotherScan = false
        for name in names where !seen.contains(name) {
            guard options != nil else { return }
            guard DownloadsWatcher.isFinishedDownload(named: name) else { continue }
            let url = folder.appendingPathComponent(name, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isHiddenKey,
            ]), values.isHidden != true, values.isDirectory != true,
                  let version = FileVersion.read(url)
            else { continue }
            if let candidate = candidates[name], candidate.version == version {
                if now.timeIntervalSince(candidate.since) >= DownloadsWatcher.settleTime, !fileIsOpen(url.path) {
                    // Cancellation/options may change during the expensive open-file check.
                    guard options != nil else { return }
                    guard version.matches(url) else { needsAnotherScan = true; continue }
                    candidates[name] = nil
                    seen.insert(name)
                    handle(url, version: version)
                } else { needsAnotherScan = true }
            } else {
                candidates[name] = (version, now)
                needsAnotherScan = true
            }
        }
        if needsAnotherScan { scheduleScan() }
    }

    private func handle(_ original: URL, version: FileVersion) {
        var url = original
        if options?.lowercase == true, let renamed = DownloadsWatcher.lowercasedExtension(of: url),
           options?.lowercase == true, DownloadsWatcher.moveCaseOnly(from: url, to: renamed) {
            seen.insert(renamed.lastPathComponent)
            url = renamed
        }
        guard let currentVersion = FileVersion.read(url), version.sameContents(as: currentVersion) else { return }
        if options?.duplicates == true,
           let duplicate = DuplicateFiles.find(for: url, in: folder, shouldContinue: { self.options?.duplicates == true }) {
            Task { @MainActor in
                guard self.options?.duplicates == true else { return }
                self.onDuplicate?(duplicate)
            }
            // Keep both copies available for review; don't auto-unzip or import the new one.
            return
        }
        if options?.invites == true, url.pathExtension.lowercased() == "ics" {
            prepareInvite(url, version: currentVersion)
        }
        if options?.archives == true, url.pathExtension.lowercased() == "zip" {
            let archive = url
            Task { @MainActor in
                await DownloadsWatcher.unzip(archive, expectedVersion: currentVersion,
                                             shouldContinue: { self.options?.archives == true },
                                             onDeferred: { self.retryArchive(archive) })
            }
        }
    }

    private func retryArchive(_ archive: URL) {
        queue.async {
            guard self.options?.archives == true else { return }
            // A changed or reopened source must settle again; do not forget it
            // permanently just because the extraction queue was busy.
            self.seen.remove(archive.lastPathComponent)
            self.candidates[archive.lastPathComponent] = nil
            self.scheduleScan()
        }
    }

    private func prepareInvite(_ original: URL, version: FileVersion) {
        guard version.matches(original), let text = try? String(contentsOf: original, encoding: .utf8),
              version.matches(original) else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "tweaks-invite-\(UUID().uuidString)")
        let copy = directory.appending(path: original.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try DownloadsWatcher.removingAlarms(from: text).write(to: copy, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        // The unique directory prevents simultaneous same-named invites from colliding.
        queue.asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: directory) }
        Task { @MainActor in
            guard self.options?.invites == true,
                  let fantastical = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DownloadsWatcher.fantasticalBundleID)
            else { return }
            NSWorkspace.shared.open([copy], withApplicationAt: fantastical, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error == nil else { return }
                self.queue.async {
                    guard self.options?.invites == true, version.matches(original) else { return }
                    try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
                }
            }
        }
    }
}

/// A name-only directory snapshot. Foundation's URL/resource machinery is unnecessary
/// when checking known names or browser partial-download suffixes in a large folder.
enum DownloadDirectory {
    static func names(in folder: URL) -> [String]? {
        guard let directory = opendir(folder.path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? names : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            // Unrepresentable names are left untouched; never replace invalid bytes
            // with another valid filename and accidentally operate on that file.
            if let name, name != ".", name != ".." { names.append(name) }
        }
    }
}
