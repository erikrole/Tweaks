import AppKit
import Foundation

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
              let app = Self.singleApp(in: volume)
        else { return }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Install \(app.deletingPathExtension().lastPathComponent)?"
        alert.informativeText = "Tweaks will copy it to Applications, eject the disk image and move \(image.lastPathComponent) to the Trash."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = URL(filePath: "/Applications").appending(path: app.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                if let bundleID = Bundle(url: destination)?.bundleIdentifier {
                    for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                        running.terminate()
                    }
                }
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try await Self.copy(app, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't install \(app.deletingPathExtension().lastPathComponent)"
            failure.informativeText = error.localizedDescription
            failure.runModal()
            return
        }

        await Self.detach(volume)
        try? FileManager.default.trashItem(at: image, resultingItemURL: nil)
        _ = try? await NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The .dmg behind a mounted volume, if it is a disk image you downloaded.
    static func diskImagePath(for volume: URL) async -> URL? {
        guard let output = await run("/usr/bin/hdiutil", ["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        else { return nil }
        return imagePath(for: volume.path, inHdiutilInfo: plist)
    }

    static func imagePath(for mountPoint: String, inHdiutilInfo plist: [String: Any]) -> URL? {
        let normalized = mountPoint.hasSuffix("/") ? String(mountPoint.dropLast()) : mountPoint
        for image in plist["images"] as? [[String: Any]] ?? [] {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard entities.contains(where: { ($0["mount-point"] as? String) == normalized }),
                  let path = image["image-path"] as? String, path.lowercased().hasSuffix(".dmg")
            else { continue }
            // Only images you downloaded, not ones mounted by installers or Time Machine.
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads").path
            return path.hasPrefix(downloads) ? URL(filePath: path) : nil
        }
        return nil
    }

    /// The one app at the top of the volume; nil if there are none or several.
    static func singleApp(in volume: URL) -> URL? {
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

    private static func detach(_ volume: URL) async {
        _ = await run("/usr/bin/hdiutil", ["detach", volume.path, "-quiet"])
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
