import AppKit
import Foundation
import Security

/// When a disk image you downloaded mounts and holds a single app, offers to install it:
/// copy to /Applications (the old copy goes to the Trash), eject the image, trash the
/// .dmg and open the new app.
@MainActor
final class DMGInstaller {
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in await self?.handleMount(volume) }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func handleMount(_ volume: URL) async {
        guard let image = await Self.diskImagePath(for: volume),
              let app = try? await FileWork.run({ Self.singleApp(in: volume) })
        else { return }

        let name = app.deletingPathExtension().lastPathComponent
        let destination = URL(filePath: "/Applications").appending(path: app.lastPathComponent)
        let incoming = await AppIdentity.read(app)
        let exists = (try? await FileWork.run { FileManager.default.fileExists(atPath: destination.path) }) == true
        let installed = exists ? await AppIdentity.read(destination) : nil
        guard observer != nil else { return }

        // Refuse what would be a downgrade or a different developer's app with the same name.
        if let problem = Self.problem(installing: incoming, over: installed) {
            Self.tell("Didn't install \(name)", problem)
            return
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = installed == nil ? "Install \(name)?" : "Update \(name) to \(incoming.version ?? "this version")?"
        alert.informativeText = "Tweaks will copy it to Applications, eject the disk image and move \(image.lastPathComponent) to the Trash."
        alert.addButton(withTitle: installed == nil ? "Install" : "Update")
        alert.addButton(withTitle: "Not Now")
        // Return means "Not Now", so a keystroke meant for another app can't install anything.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Copy next to the destination first; the installed app is only replaced once the
        // new copy is complete and passes Gatekeeper, so there's never a moment without it.
        let staging = URL(filePath: "/Applications").appending(path: ".\(app.lastPathComponent).tweaks-staging-\(UUID().uuidString)")
        var recoveryNote: String?
        do {
            try await Self.copy(app, to: staging)
            guard await Self.passesGatekeeper(staging) else {
                await Self.remove(staging)
                Self.tell("Didn't install \(name)", "macOS's Gatekeeper check rejected this copy, so the app you have is unchanged.")
                return
            }
            if installed != nil {
                guard await Self.quitAndWait(bundleID: incoming.bundleID ?? installed?.bundleID) else {
                    await Self.remove(staging)
                    Self.tell("Didn't update \(name)", "\(name) is still open. Quit it (saving your work) and open the disk image again.")
                    return
                }
                recoveryNote = try await FileWork.run { try Self.replaceApp(at: destination, with: staging) }
            } else {
                try await FileWork.run { try FileManager.default.moveItem(at: staging, to: destination) }
            }
        } catch {
            await Self.remove(staging)
            Self.tell("Couldn't install \(name)", error.localizedDescription)
            return
        }

        let cleanupNote = await Self.finishImage(image, detach: { await Self.detach(volume) }, trash: { image in
            try await FileWork.run { try FileManager.default.trashItem(at: image, resultingItemURL: nil) }
        })
        let notes = [recoveryNote, cleanupNote].compactMap { $0 }
        if !notes.isEmpty { Self.tell("Installed \(name)", notes.joined(separator: "\n\n")) }
        _ = try? await NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Retain an on-volume backup through the atomic replacement. If Trash fails,
    /// keep the backup and tell the user exactly where it can be recovered.
    nonisolated static func replaceApp(at destination: URL, with staging: URL,
                                       trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> String? {
        let backupName = "\(destination.deletingPathExtension().lastPathComponent) previous \(UUID().uuidString).app"
        let backup = destination.deletingLastPathComponent().appending(path: backupName)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging, backupItemName: backupName,
                                                 options: [.withoutDeletingBackupItem])
        do { try trash(backup); return nil }
        catch { return "The previous app is preserved at \(backup.path). It could not be moved to the Trash: \(error.localizedDescription)" }
    }

    static func finishImage(_ image: URL, detach: () async -> Bool,
                            trash: (URL) async throws -> Void) async -> String? {
        guard await detach() else {
            return "The disk image could not be ejected. Its downloaded file was kept. Eject it in Finder when it is no longer in use."
        }
        do { try await trash(image); return nil }
        catch { return "The disk image was ejected, but \(image.lastPathComponent) could not be moved to the Trash: \(error.localizedDescription)" }
    }

    /// Why an install should be refused, or nil if it's fine.
    static func problem(installing incoming: AppIdentity, over installed: AppIdentity?) -> String? {
        guard let installed else { return nil }
        if let new = incoming.teamID, let old = installed.teamID, new != old {
            return "It's signed by a different developer than the \(installed.name) you have, so it may not be the same app."
        }
        if let new = incoming.version, let old = installed.version,
           new.compare(old, options: .numeric) == .orderedAscending {
            return "It's an older version (\(new)) than the one you have (\(old))."
        }
        return nil
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Asks the app to quit (it may show a Save sheet) and waits up to 15 s.
    private static func quitAndWait(bundleID: String?) async -> Bool {
        guard let bundleID else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        for _ in 0..<30 {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return running.allSatisfy(\.isTerminated)
    }

    private static func passesGatekeeper(_ app: URL) async -> Bool {
        await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) != nil
    }

    /// The .dmg behind a mounted volume, if it is a disk image you downloaded.
    static func diskImagePath(for volume: URL) async -> URL? {
        guard let output = await run("/usr/bin/hdiutil", ["info", "-plist"]) else { return nil }
        return try? await FileWork.run {
            guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
            else { return nil }
            return imagePath(for: volume.path, inHdiutilInfo: plist)
        }
    }

    nonisolated static func imagePath(for mountPoint: String, inHdiutilInfo plist: [String: Any]) -> URL? {
        let normalized = mountPoint.hasSuffix("/") ? String(mountPoint.dropLast()) : mountPoint
        for image in plist["images"] as? [[String: Any]] ?? [] {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard entities.contains(where: { ($0["mount-point"] as? String) == normalized }),
                  let path = image["image-path"] as? String, path.lowercased().hasSuffix(".dmg")
            else { continue }
            // Only images you downloaded, not ones mounted by installers or Time Machine.
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
            let candidate = URL(filePath: path)
            return isInside(candidate, directory: downloads) ? candidate : nil
        }
        return nil
    }

    nonisolated static func isInside(_ file: URL, directory: URL) -> Bool {
        func canonicalComponents(_ url: URL) -> [String] {
            // Foundation may leave a symlink unresolved when the final leaf does
            // not exist. Resolve the closest existing ancestor as well.
            var ancestor = url.standardizedFileURL
            var suffix: [String] = []
            while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
                suffix.insert(ancestor.lastPathComponent, at: 0)
                ancestor.deleteLastPathComponent()
            }
            return ancestor.resolvingSymlinksInPath().standardizedFileURL.pathComponents + suffix
        }
        let root = canonicalComponents(directory)
        let parts = canonicalComponents(file)
        return parts.count > root.count && parts.starts(with: root)
    }

    /// The one app at the top of the volume; nil if there are none or several.
    nonisolated static func singleApp(in volume: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let apps = items.filter { $0.pathExtension == "app" }
        return apps.count == 1 ? apps[0] : nil
    }

    private static func copy(_ app: URL, to destination: URL) async throws {
        // ditto keeps code signatures, extended attributes and symlinks intact.
        guard await run("/usr/bin/ditto", [app.path, destination.path]) != nil else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func detach(_ volume: URL) async -> Bool {
        await run("/usr/bin/hdiutil", ["detach", volume.path, "-quiet"]) != nil
    }

    private static func remove(_ url: URL) async {
        try? await FileWork.run { try FileManager.default.removeItem(at: url) }
    }

    /// Runs a tool off the main thread; nil on failure.
    private static func run(_ tool: String, _ arguments: [String]) async -> Data? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }
}

/// The bits of an app bundle used to judge whether replacing it is safe.
struct AppIdentity: Equatable, Sendable {
    let name: String
    let bundleID: String?
    let version: String?
    let teamID: String?

    /// Bundle and signature inspection can block on disk and Security services.
    /// Keep it off the main actor so mounting a DMG does not stall shortcuts or UI.
    static func read(_ url: URL) async -> AppIdentity {
        await Task.detached(priority: .utility) { readSynchronously(url) }.value
    }

    private static func readSynchronously(_ url: URL) -> AppIdentity {
        let bundle = Bundle(url: url)
        let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        return AppIdentity(
            name: url.deletingPathExtension().lastPathComponent,
            bundleID: bundle?.bundleIdentifier,
            version: version,
            teamID: teamIdentifier(of: url)
        )
    }

    private static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
