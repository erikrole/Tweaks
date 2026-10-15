import Cocoa
import FinderSync
import FinderUtilitiesKit
import OSLog

private let log = Logger(subsystem: "com.erole.Tweaks.FinderSync", category: "menu")

/// Thin Finder Sync adapter. `menu(for:)` does no file I/O: it only builds strings.
final class FinderSyncExtension: FIFinderSync {
    private var selection: [URL] = []
    private let metadata = MetadataService(providers: [FileAttributeProvider(), AVMetadataProvider(), ImageMetadataProvider()])
    private let formatter = MetadataFormatter()

    override init() {
        super.init()
        // "/" alone does not reliably cover network volumes; ScopeController adds each volume root.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        Task { @MainActor in ScopeController.shared.start() }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let controller = FIFinderSyncController.default()
        selection = controller.selectedItemURLs() ?? controller.targetedURL().map { [$0] } ?? []
        guard !selection.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: selection.count > 1 ? "Copy \(selection.count) Paths" : "Copy Path",
                              action: #selector(copyCleanPath(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)

        let original = NSMenuItem(title: "Copy Original Path", action: #selector(copyOriginalPath(_:)), keyEquivalent: "")
        original.target = self
        menu.addItem(original)

        // Never wait for metadata while Finder is constructing a menu. The same cached
        // result serves the top-level line and submenu; cold reads show Loading….
        var state: MetadataState?
        if selection.count == 1, let url = selection.first, !url.hasDirectoryPath {
            state = metadata.menuState(for: url)
            log.info("inspect \(VolumeInfo.classify(path: url.path).key, privacy: .public): \(String(describing: state), privacy: .public)")
        }
        for line in quickInfo(state) { menu.addItem(line) }
        menu.addItem(inspectItem(state))
        if let request = ImageActionRequest.url(for: selection) {
            let images = NSMenuItem(title: "Quick Image Actions…", action: #selector(openImageActions(_:)), keyEquivalent: "")
            images.target = self
            images.representedObject = request
            menu.addItem(images)
        }
        return menu
    }

    /// Frame size and other quick facts shown directly on the main menu for a single file.
    private func quickInfo(_ state: MetadataState?) -> [NSMenuItem] {
        guard let state, let text = formatter.summary(for: state) else { return [] }
        let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        row.isEnabled = false
        return [row]
    }

    /// Reads only the in-memory cache and kicks off a background prefetch; no I/O happens here.
    /// First open shows "Loading…"; reopening the menu shows the values.
    private func inspectItem(_ state: MetadataState?) -> NSMenuItem {
        let item = NSMenuItem(title: "Inspect Media", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Inspect Media")
        if selection.count == 1, let url = selection.first, url.hasDirectoryPath {
            // Finder marks folders in the URL itself, so no I/O is needed to tell.
            let row = NSMenuItem(title: "Folder (select a media file)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            sub.addItem(row)
        } else if selection.count == 1, let state {
            for line in formatter.lines(for: state) {
                let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                row.isEnabled = false
                sub.addItem(row)
            }
        } else {
            let row = NSMenuItem(title: "Select one item", action: nil, keyEquivalent: "")
            row.isEnabled = false
            sub.addItem(row)
        }
        item.submenu = sub
        return item
    }

    @objc private func copyCleanPath(_ sender: Any?) {
        write(PathCleaner().clean(selection))
    }

    @objc private func copyOriginalPath(_ sender: Any?) {
        write(selection.map { $0.path(percentEncoded: false) }.joined(separator: "\n"))
    }

    @objc private func openImageActions(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(request)
    }

    private func write(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.setString(text.replacingOccurrences(of: "\0", with: ""), forType: .string) {
            log.error("pasteboard write failed")
            NSSound.beep()
        }
    }
}
