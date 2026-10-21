import AppKit
import ImageIO
import UniformTypeIdentifiers
import FinderUtilitiesKit
import XCTest
@testable import Tweaks

@MainActor
final class NewTweakTests: XCTestCase {
    func testNewAutomaticFeaturesAreOptInAndPersist() {
        let domain = "new-features-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = TweakSettings(defaults: defaults)
        for tweak in [Tweak.windowLayouts, .deviceVolumeLimits, .duplicateDownloads, .safeEjectHotKey, .preferEthernetForVPN] {
            XCTAssertFalse(settings.isOn(tweak))
            settings.set(tweak, on: true)
            XCTAssertTrue(TweakSettings(defaults: defaults).isOn(tweak))
        }
        for action in [ShortcutAction.safeEject, .saveWindowLayout, .restoreWindowLayout] {
            XCTAssertNil(action.defaultShortcut)
        }
    }

    func testDisplayLayoutIdentityIgnoresEnumerationOrderButNotArrangement() {
        let a = LayoutDisplay(id: "A", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: .zero)
        let b = LayoutDisplay(id: "B", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visible: .zero)
        XCTAssertEqual(LayoutDisplay.key([a, b]), LayoutDisplay.key([b, a]))
        XCTAssertNotEqual(LayoutDisplay.key([a]), LayoutDisplay.key([a, b]))
        let moved = LayoutDisplay(id: "B", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: .zero)
        XCTAssertNotEqual(LayoutDisplay.key([a, b]), LayoutDisplay.key([a, moved]))
    }

    func testRestoredWindowFitsAvailableScreenWithoutLosingNegativeCoordinates() {
        let screen = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        XCTAssertEqual(LayoutDisplay.fit(CGRect(x: -4000, y: -100, width: 3000, height: 2000), in: screen), screen)
        let normal = CGRect(x: -1600, y: 100, width: 800, height: 600)
        XCTAssertEqual(LayoutDisplay.fit(normal, in: screen), normal)
    }

    func testWindowIdentityUsesDocumentWithoutPersistingItsName() throws {
        let id = try XCTUnwrap(SavedWindow.identity(identifier: "AX123", document: "file:///private/project.mov", title: "Changed Title"))
        XCTAssertEqual(id, SavedWindow.identity(identifier: "OTHER", document: "file:///private/project.mov", title: "Original"))
        XCTAssertFalse(id.contains("project"))
        XCTAssertEqual(id.count, 64)
        XCTAssertNil(SavedWindow.identity(identifier: "", document: nil, title: nil))
    }

    func testVolumeLimitsNeverRaiseVolumeAndRulesUseDeviceUID() {
        XCTAssertNil(DeviceVolumeRule.target(current: 0.2, maximum: 0.4))
        XCTAssertNil(DeviceVolumeRule.target(current: 0.4, maximum: 0.4))
        XCTAssertEqual(DeviceVolumeRule.target(current: 0.9, maximum: 0.4), 0.4)
        XCTAssertEqual(DeviceVolumeRule.target(current: 0.9, maximum: -2), 0)
        XCTAssertNil(DeviceVolumeRule.target(current: .nan, maximum: 0.4))
        let domain = "volume-rules-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let limits = DeviceVolumeLimits(defaults: defaults)
        limits.setRule(.init(name: "Same name", maximum: 0.3, muteOnSwitchAway: true), for: "UID-A")
        limits.setRule(.init(name: "Same name", maximum: 0.7), for: "UID-B")
        let loaded = DeviceVolumeLimits(defaults: defaults)
        XCTAssertEqual(loaded.rules["UID-A"]?.maximum, 0.3)
        XCTAssertEqual(loaded.rules["UID-B"]?.maximum, 0.7)
        XCTAssertEqual(loaded.rules["UID-A"]?.muteOnSwitchAway, true)
    }

    func testQuantizedVolumeIsBoundedAndRepeatedNotificationsDoNotLoop() {
        var enforcer = VolumeLimitEnforcer()
        var volume: Float = 0.9
        var writes = 0
        let result = enforcer.enforce(current: volume, maximum: 0.4, write: { request in
            writes += 1
            volume = (request * 64).rounded() / 64
            return true
        }, read: { volume })
        XCTAssertEqual(result, .applied(volume))
        XCTAssertLessThanOrEqual(volume, 0.4)
        XCTAssertLessThanOrEqual(writes, 3)

        enforcer.reset()
        volume = 0.9
        writes = 0
        // A broken/immutable driver reports the same above-limit value after every
        // write and emits another event. Processing 100 events must remain bounded.
        for _ in 0..<100 {
            _ = enforcer.enforce(current: volume, maximum: 0.4, write: { _ in
                writes += 1
                volume = 0.40625
                return true
            }, read: { volume })
        }
        XCTAssertEqual(writes, 3)
        _ = enforcer.enforce(current: 0.2, maximum: 0.4, write: { _ in XCTFail("Must not raise volume"); return true }, read: { 0.2 })
        let resumed = enforcer.enforce(current: 0.8, maximum: 0.4, write: { volume = $0; return true }, read: { volume })
        XCTAssertEqual(resumed, .applied(0.4))
    }

    func testImageRequestsRoundTripUnicodeAndRejectUntrustedOptions() throws {
        let files = [URL(fileURLWithPath: "/tmp/Photo & café %2F.png"), URL(fileURLWithPath: "/tmp/末尾.jpg")]
        let request = try XCTUnwrap(ImageActionRequest.url(for: files))
        XCTAssertEqual(ImageActionRequest.files(from: request), files)
        XCTAssertNil(ImageActionRequest.files(from: URL(string: "tweaks://images?file=relative.png")!))
        XCTAssertNil(ImageActionRequest.files(from: URL(string: "tweaks://images?file=/tmp/a.png&destination=/tmp/out")!))
        XCTAssertNil(ImageActionRequest.files(from: URL(string: "tweaks://images?file=/tmp/not-image.sh")!))
        XCTAssertNil(ImageActionRequest.url(for: Array(repeating: files[0], count: 21)))
    }

    func testImageExportResizesStripsLocationAndNeverOverwrites() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Photo.jpg")
        try Self.makeImage(at: source, type: .jpeg, orientation: 1)
        let original = try Data(contentsOf: source)
        let first = try await FileWork.run {
            try ImageExporter.export(source, options: .init(format: .png, longestEdge: 20, removeMetadata: true), to: folder)
        }
        let second = try await FileWork.run {
            try ImageExporter.export(source, options: .init(format: .png, longestEdge: 20, removeMetadata: true), to: folder)
        }
        XCTAssertNotEqual(first, second)
        let properties = try Self.properties(first)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 20)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 10)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testHEICExportPreservesDimensionsAndStripsLocation() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Photo.png")
        try Self.makeImage(at: source, type: .png, orientation: 1)
        let output = try await FileWork.run {
            try ImageExporter.export(source, options: .init(format: .heic, longestEdge: nil, removeMetadata: true), to: folder)
        }
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.heic.identifier)
        let properties = try Self.properties(output)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 80)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 40)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
    }

    func testJPEGExportCompositesTransparencyOnWhite() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Transparent.png")
        try Self.makeImage(at: source, type: .png, orientation: 1)
        let output = try await FileWork.run {
            try ImageExporter.export(source, options: .init(format: .jpeg, longestEdge: nil, removeMetadata: true), to: folder)
        }
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixel[0], 240)
        // The fixture is 70% red: white compositing leaves about 30% green/blue.
        XCTAssertEqual(Int(pixel[1]), 77, accuracy: 8)
        XCTAssertEqual(Int(pixel[2]), 77, accuracy: 8)
        XCTAssertEqual(pixel[3], 255)
    }

    func testImageExportAppliesOrientationOnceAndCanKeepLocation() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Rotated.tiff")
        try Self.makeImage(at: source, type: .tiff, orientation: 6)
        let output = try await FileWork.run {
            try ImageExporter.export(source, options: .init(format: .jpeg, longestEdge: nil, removeMetadata: false), to: folder)
        }
        let properties = try Self.properties(output)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 40)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 80)
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int ?? 1, 1)
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation as String] as? Int ?? 1, 1)
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary as String])
    }

    func testImageExporterRejectsAnimationAndInvalidInputWithoutPublishing() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let animated = folder.appending(path: "Animated.gif")
        try Self.makeImage(at: animated, type: .gif, orientation: 1, frames: 2)
        let invalid = folder.appending(path: "Not an image.png")
        try Data("not an image".utf8).write(to: invalid)
        for file in [animated, invalid] {
            do {
                _ = try await FileWork.run { try ImageExporter.export(file, options: .init(), to: folder) }
                XCTFail("Invalid or multi-frame input must not be published")
            } catch { XCTAssertTrue(error is ImageExportError) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testDuplicateDetectionRequiresMatchingContentsAndExcludesHardLinksAndForks() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "Old.txt")
        let new = folder.appending(path: "New.txt")
        try Data("same content".utf8).write(to: old)
        try Data("other string".utf8).write(to: new)
        var match = try await FileWork.run { DuplicateFiles.find(for: new, in: folder) }
        XCTAssertNil(match)
        try Data("same content".utf8).write(to: new)
        match = try await FileWork.run { DuplicateFiles.find(for: new, in: folder) }
        let duplicate = try XCTUnwrap(match)
        XCTAssertEqual(duplicate.existingFile, old)
        let valid = try await FileWork.run { try DuplicateFiles.validate(duplicate) }
        XCTAssertTrue(valid)
        try Data("replacement".utf8).write(to: old, options: .atomic)
        let stale = try await FileWork.run { try DuplicateFiles.validate(duplicate) }
        XCTAssertFalse(stale)
        try FileManager.default.removeItem(at: old)
        try FileManager.default.linkItem(at: new, to: old)
        let linked = try await FileWork.run { DuplicateFiles.find(for: new, in: folder) }
        XCTAssertNil(linked)
        try FileManager.default.removeItem(at: old)
        try Data("same content".utf8).write(to: old)
        let resource = Data("unique resource-fork data".utf8)
        let status = resource.withUnsafeBytes { setxattr(new.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(status, 0)
        let forked = try await FileWork.run { DuplicateFiles.find(for: new, in: folder) }
        XCTAssertNil(forked)
    }

    func testDuplicateHashCanBeCancelled() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Large.bin")
        try Data(repeating: 0x31, count: 3_000_000).write(to: file)
        var chunks = 0
        XCTAssertThrowsError(try DuplicateFiles.digest(file, shouldContinue: { chunks += 1; return chunks < 3 })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testNewDuplicateIsOfferedOnceAndPreservedForReview() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "Existing.zip")
        let new = folder.appending(path: "New.zip")
        let data = Data("same fixture; never extract a duplicate before review".utf8)
        try data.write(to: old)
        let watcher = DownloadsWatcher(folder: folder, fileIsOpen: { _ in false })
        watcher.detectDuplicates = true
        watcher.unzipArchives = true
        let offered = expectation(description: "duplicate review")
        offered.assertForOverFulfill = true
        watcher.onDuplicate = { match in
            XCTAssertEqual(match.newFile, new)
            XCTAssertEqual(match.existingFile, old)
            offered.fulfill()
        }
        watcher.start()
        await watcher.waitUntilReady()
        defer { watcher.stop() }
        try data.write(to: new)
        let now = Date()
        await watcher.scan(now: now)
        await watcher.scan(now: now.addingTimeInterval(2))
        await fulfillment(of: [offered], timeout: 2)
        await watcher.scan(now: now.addingTimeInterval(4))
        XCTAssertEqual(try Data(contentsOf: new), data)
        XCTAssertEqual(try Data(contentsOf: old), data)
    }

    func testSafeEjectSkipsInternalRootUnknownAndMalformedDevices() {
        XCTAssertTrue(SafeEjectEngine.eligible(local: true, root: false, internalDrive: false, ejectable: true, removable: false))
        XCTAssertFalse(SafeEjectEngine.eligible(local: true, root: true, internalDrive: false, ejectable: true, removable: true))
        XCTAssertFalse(SafeEjectEngine.eligible(local: true, root: false, internalDrive: true, ejectable: true, removable: true))
        XCTAssertFalse(SafeEjectEngine.eligible(local: nil, root: false, internalDrive: false, ejectable: true, removable: true))
        XCTAssertFalse(SafeEjectEngine.eligible(local: false, root: false, internalDrive: false, ejectable: true, removable: true))
        for invalid in ["disk", "disk0s1", "../disk9", "disk9;rm", "disk９"] { XCTAssertFalse(SafeEjectEngine.validDevice(invalid)) }
        XCTAssertTrue(SafeEjectEngine.validDevice("disk19"))
    }

    func testAPFSContainersResolveToTheirPhysicalSiblingsAndRejectUnknownStores() throws {
        let topology = try EjectTopology(plist: ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk4", "Content": "GUID_partition_scheme", "Partitions": [
                ["DeviceIdentifier": "disk4s1", "Content": "Apple_APFS"],
                ["DeviceIdentifier": "disk4s2", "Content": "Microsoft Basic Data"]]],
            ["DeviceIdentifier": "disk5", "Content": "Apple_APFS_Container",
             "APFSPhysicalStores": [["DeviceIdentifier": "disk4s1"]]],
            ["DeviceIdentifier": "disk6", "Content": "Apple_APFS_Container",
             "APFSPhysicalStores": [["DeviceIdentifier": "disk4s1"], ["DeviceIdentifier": "disk8s1"]]],
            ["DeviceIdentifier": "disk7", "Content": "Apple_APFS_Container",
             "APFSPhysicalStores": [["DeviceIdentifier": "disk99s1"]]],
        ]])
        XCTAssertEqual(topology.physicalDevice(for: "disk5"), "disk4")
        XCTAssertEqual(topology.physicalDevice(for: "disk4"), "disk4")
        XCTAssertNil(topology.physicalDevice(for: "disk6"))
        XCTAssertNil(topology.physicalDevice(for: "disk7"))
        XCTAssertNil(topology.physicalDevice(for: "disk999"))
        XCTAssertThrowsError(try EjectTopology(plist: [:]))
    }

    func testSafeEjectDistinguishesPseudoMountsFromDiskBackedAliases() {
        XCTAssertEqual(SafeEjectEngine.mountSource("/dev/disk5s1", type: "apfs"), .disk("/dev/disk5s1"))
        XCTAssertEqual(SafeEjectEngine.mountSource("devices", type: "devicefs"), .pseudo)
        XCTAssertEqual(SafeEjectEngine.mountSource("/Applications/Example.app/Wrapper", type: "nullfs"),
                       .alias("/Applications/Example.app/Wrapper"))
        XCTAssertEqual(SafeEjectEngine.mountSource("relative", type: "nullfs"), .unsupported)
        XCTAssertEqual(SafeEjectEngine.mountSource("third-party", type: "fusefs"), .unsupported)
    }

    func testSafeEjectChecksAllSiblingVolumesAndNeverForcesBusyOrUnknownDrives() {
        let drive = Self.drive
        for users: [String]? in [["Premiere"], nil] {
            let state = EjectTestState()
            let backend = SafeEjectEngine.Backend(drives: { [drive] }, users: { volume in
                volume.lastPathComponent == "B" ? users : []
            }, rendering: { false }, eject: { _ in state.recordEject() })
            let report = SafeEjectEngine.run(backend)
            XCTAssertEqual(state.ejects, 0)
            XCTAssertFalse(report.isEmpty)
        }
        let state = EjectTestState()
        let backend = SafeEjectEngine.Backend(drives: { [drive] }, users: { _ in [] }, rendering: { false }, eject: { _ in state.recordEject() })
        XCTAssertEqual(SafeEjectEngine.run(backend), ["Ejected A / B."])
        XCTAssertEqual(state.ejects, 1)
    }

    func testSafeEjectRevalidatesIdentityAndRenderAfterOpenFileCheck() {
        let drive = Self.drive
        let swapped = EjectDrive(device: drive.device, name: drive.name, volumes: drive.volumes, identity: "DIFFERENT")
        for changesIdentity in [true, false] {
            let state = EjectTestState()
            let backend = SafeEjectEngine.Backend(drives: { [state.changed && changesIdentity ? swapped : drive] },
                                                 users: { _ in state.markChanged(); return [] },
                                                 rendering: { state.changed && !changesIdentity },
                                                 eject: { _ in state.recordEject() })
            _ = SafeEjectEngine.run(backend)
            XCTAssertEqual(state.ejects, 0)
        }
    }

    private static var drive: EjectDrive {
        EjectDrive(device: "disk9", name: "A / B", volumes: [URL(fileURLWithPath: "/Volumes/A"), URL(fileURLWithPath: "/Volumes/B")], identity: "A|B")
    }

    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tweaks-new-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func properties(_ file: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private static func makeImage(at file: URL, type: UTType, orientation: Int, frames: Int = 1) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 0.7])!)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, frames, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: orientation],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 43.0, kCGImagePropertyGPSLatitudeRef: "N",
                                          kCGImagePropertyGPSLongitude: 89.0, kCGImagePropertyGPSLongitudeRef: "W"],
        ]
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class EjectTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var didChange = false
    private var count = 0
    var changed: Bool { lock.withLock { didChange } }
    var ejects: Int { lock.withLock { count } }
    func markChanged() { lock.withLock { didChange = true } }
    func recordEject() { lock.withLock { count += 1 } }
}
