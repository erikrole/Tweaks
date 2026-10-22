import AppKit
import ImageIO
import UniformTypeIdentifiers
import FinderUtilitiesKit

struct ImageExportOptions: Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case jpeg, png, heic
        var id: String { rawValue }
        var type: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .heic: .heic } }
        var suffix: String { self == .jpeg ? "jpg" : rawValue }
    }
    var format: Format = .jpeg
    var longestEdge: Int? = 2048
    var removeMetadata = true
}

enum ImageExportError: LocalizedError {
    case unreadable, multipleFrames, changed, tooLarge, writeFailed
    var errorDescription: String? {
        switch self {
        case .unreadable: "This file could not be read as an image."
        case .multipleFrames: "Animated and multi-page images are left unchanged. Choose a single-frame image."
        case .changed: "The source changed during export. Try again once it has finished saving."
        case .tooLarge: "This image is too large to export at original size. Choose a smaller longest edge."
        case .writeFailed: "The image copy could not be written. Check the format and destination permissions."
        }
    }
}

enum ImageExporter {
    static func export(_ file: URL, options: ImageExportOptions, to folder: URL) throws -> URL {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let version = FileVersion.read(file),
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { throw ImageExportError.unreadable }
        guard CGImageSourceGetCount(source) == 1 else { throw ImageExportError.multipleFrames }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { throw ImageExportError.unreadable }
        if options.longestEdge == nil && (Double(width) * Double(height) > 120_000_000 || max(width, height) > 32_768) {
            throw ImageExportError.tooLarge
        }
        let limit = min(options.longestEdge.map { min(16_384, max(1, $0)) } ?? max(width, height), max(width, height))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { throw ImageExportError.unreadable }
        if options.format == .jpeg { image = try flatten(image) }
        // ImageIO may replace its destination and reset its permissions. A private
        // staging directory keeps the in-progress file private throughout encoding.
        let staging = folder.appending(path: ".tweaks-image-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appending(path: "image.\(options.format.suffix)")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, options.format.type.identifier as CFString, 1, nil) else {
            throw ImageExportError.writeFailed
        }
        // Removing metadata deliberately removes all descriptive metadata, including
        // GPS in EXIF/XMP. Pixels and their color space are retained in the CGImage.
        var output = options.removeMetadata ? [:] : properties
        output[kCGImagePropertyOrientation as String] = 1
        if var tiff = output[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            output[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        output.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        output.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var exif = output[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            output[kCGImagePropertyExifDictionary as String] = exif
        }
        output[kCGImageDestinationLossyCompressionQuality as String] = 0.9
        CGImageDestinationAddImage(destination, image, output as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageExportError.writeFailed }
        guard chmod(temporary.path, 0o600) == 0 else { throw ImageExportError.writeFailed }
        guard version.matches(file) else { throw ImageExportError.changed }
        let base = file.deletingPathExtension().lastPathComponent + " - Tweaks"
        // Publish atomically beside the source/destination without replacing any file.
        for index in 1...999 {
            let name = base + (index == 1 ? "" : " \(index)") + "." + options.format.suffix
            let target = folder.appending(path: name)
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw ImageExportError.writeFailed }
        }
        throw ImageExportError.writeFailed
    }

    private static func flatten(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImageExportError.writeFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ImageExportError.writeFailed }
        return result
    }
}

@MainActor
final class ImageActions {
    private var window: NSWindow?
    var onAction: ((String) -> Void)?

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        show(panel.urls)
    }

    func show(_ files: [URL]) {
        guard !files.isEmpty, files.count <= ImageActionRequest.maximumFiles else { return }
        // Keep an in-progress export visible; another request must not replace its UI.
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Quick Image Actions"
        window.isReleasedWhenClosed = false
        let panel = ImageActionsPanel(files: files)
        panel.onAction = onAction
        window.contentView = panel.view
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.panel = panel
    }

    private var panel: ImageActionsPanel?
}

/// AppKit only, like the rest of Tweaks: SwiftUI is never mapped for this panel.
@MainActor
private final class ImageActionsPanel: NSObject {
    var onAction: ((String) -> Void)?
    let view = NSView()
    private let files: [URL]
    private let format = NSPopUpButton()
    private let edge = NSPopUpButton()
    private let metadata = NSButton(checkboxWithTitle: "Remove metadata, including location", target: nil, action: nil)
    private let save = NSButton(title: "Save Copies", target: nil, action: nil)
    private let showCopiesButton = NSButton(title: "Show Copies", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Originals are kept. Exports get a new name beside each source.")
    private var outputs: [URL] = []
    private let edges = [0, 1024, 2048, 4096]

    init(files: [URL]) {
        self.files = files
        super.init()
        format.addItems(withTitles: ImageExportOptions.Format.allCases.map { $0.rawValue.uppercased() })
        edge.addItems(withTitles: edges.map { $0 == 0 ? "Original size" : "\($0) pixels" })
        edge.selectItem(at: 2)
        metadata.state = .on
        save.target = self
        save.action = #selector(exportCopies)
        save.bezelStyle = .rounded
        showCopiesButton.target = self
        showCopiesButton.action = #selector(showCopies)
        showCopiesButton.bezelStyle = .rounded
        showCopiesButton.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true

        let list = NSTextField(wrappingLabelWithString: files.map(\.path).joined(separator: "\n"))
        list.font = .systemFont(ofSize: 11)
        list.isSelectable = true
        list.preferredMaxLayoutWidth = 460
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let note = NSTextField(wrappingLabelWithString: "JPEG uses a white background for transparency. Animated and multi-page images are left unchanged.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [spinner, save, showCopiesButton])
        buttons.spacing = 8
        let column = NSStackView(views: [
            NSTextField(labelWithString: "Selected images (\(files.count))"), scroll,
            row("Format", format), row("Longest edge", edge), metadata, note, buttons, statusLabel,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            note.widthAnchor.constraint(equalTo: column.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 8
        return row
    }

    @objc private func showCopies() {
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    @objc private func exportCopies() {
        let formats = ImageExportOptions.Format.allCases
        let chosen = formats[max(0, min(format.indexOfSelectedItem, formats.count - 1))]
        let longest = edges[max(0, min(edge.indexOfSelectedItem, edges.count - 1))]
        let options = ImageExportOptions(format: chosen, longestEdge: longest == 0 ? nil : longest,
                                         removeMetadata: metadata.state == .on)
        save.isEnabled = false
        showCopiesButton.isHidden = true
        spinner.startAnimation(nil)
        outputs = []
        Task { @MainActor in
            var errors: [String] = []
            for file in files {
                do {
                    let output = try await FileWork.run { try ImageExporter.export(file, options: options, to: file.deletingLastPathComponent()) }
                    outputs.append(output)
                } catch { errors.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            statusLabel.stringValue = "Saved \(outputs.count) of \(files.count) copies." + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
            onAction?("Image export saved \(outputs.count) of \(files.count) copies. Originals were kept." + (errors.isEmpty ? "" : " Review export errors in Quick Image Actions."))
            showCopiesButton.isHidden = outputs.isEmpty
            spinner.stopAnimation(nil)
            save.isEnabled = true
        }
    }
}
