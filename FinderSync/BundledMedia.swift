import FinderUtilitiesKit
import Foundation
import ObjectiveC

/// Reads media facts from `TweaksMedia.bundle` the first time a real file is inspected.
/// The extension does not link AVFoundation or ImageIO, so those frameworks are not
/// mapped while Finder Sync is idle.
struct BundledMediaProvider: MetadataProvider {
    func metadata(for url: URL) async throws -> MediaMetadata {
        let raw: [String: Any] = await withCheckedContinuation { continuation in
            // Block on a GCD thread. Waiting here on a Swift task can deadlock the
            // cooperative pool, because the bundle's own read schedules a task.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: MediaLibrary.facts(for: url.path) ?? [:])
            }
        }
        var metadata = MediaMetadata()
        MediaFacts(dictionary: raw).apply(to: &metadata)
        return metadata
    }
}

enum MediaLibrary {
    private static let lock = NSLock()
    private static var reader: AnyClass?
    private static var gaveUp = false

    static func facts(for path: String) -> [String: Any]? {
        lock.lock()
        let cls = load()
        lock.unlock()
        guard let cls, let dict = invoke(cls, path: path) else { return nil }
        var out: [String: Any] = [:]
        for key in dict.allKeys {
            guard let name = key as? String else { continue }
            out[name] = dict[name]
        }
        return out
    }

    private static func load() -> AnyClass? {
        if let reader { return reader }
        if gaveUp { return nil }
        guard let url = bundleURL() else { gaveUp = true; return nil }
        let bundle = Bundle(url: url)
        guard bundle?.load() == true else { gaveUp = true; return nil }
        let cls = bundle?.principalClass ?? NSClassFromString("TweaksMediaReader")
        guard let cls else { gaveUp = true; return nil }
        reader = cls
        return cls
    }

    static func bundleURL(in extensionBundle: Bundle = Bundle(for: FinderSyncExtension.self)) -> URL? {
        let name = "TweaksMedia.bundle"
        let candidates = [
            extensionBundle.resourceURL?.appending(path: name),
            extensionBundle.privateFrameworksURL?.appending(path: name),
            extensionBundle.builtInPlugInsURL?.appending(path: name),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func invoke(_ cls: AnyClass, path: String) -> NSDictionary? {
        let sel = NSSelectorFromString("factsForPath:")
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<NSDictionary>?
        let imp = unsafeBitCast(class_getMethodImplementation(meta, sel), to: Fn.self)
        return imp(cls, sel, path as NSString)?.takeUnretainedValue()
    }
}
