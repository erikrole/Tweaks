import FinderUtilitiesKit
import Foundation
import ObjectiveC
import os

/// Reads media facts from `TweaksMedia.bundle` the first time a real file is inspected.
/// The extension does not link AVFoundation or ImageIO, so those frameworks are not
/// mapped while Finder Sync is idle.
struct BundledMediaProvider: MetadataProvider {
    func metadata(for url: URL) async throws -> MediaMetadata {
        let path = url.path
        // MediaFacts is Sendable. The raw dictionary is not, so it stays on the GCD thread.
        // Waiting here on a Swift task can deadlock the cooperative pool, because the
        // bundle's own read schedules a task.
        let facts: MediaFacts = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let raw = MediaLibrary.facts(for: path) ?? [:]
                continuation.resume(returning: MediaFacts(dictionary: raw))
            }
        }
        var metadata = MediaMetadata()
        facts.apply(to: &metadata)
        return metadata
    }
}

enum MediaLibrary {
    /// `AnyClass` is not Sendable. The unfair lock is the only way into this cache.
    private struct Cache: @unchecked Sendable {
        var reader: AnyClass?
        var gaveUp = false
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    static func facts(for path: String) -> [String: Any]? {
        let cls = cache.withLock(load)
        guard let cls, let dict = invoke(cls, path: path) else { return nil }
        var out: [String: Any] = [:]
        for key in dict.allKeys {
            guard let name = key as? String else { continue }
            out[name] = dict[name]
        }
        return out
    }

    private static func load(_ cache: inout Cache) -> AnyClass? {
        if let reader = cache.reader { return reader }
        if cache.gaveUp { return nil }
        guard let url = bundleURL() else { cache.gaveUp = true; return nil }
        let bundle = Bundle(url: url)
        guard bundle?.load() == true else { cache.gaveUp = true; return nil }
        let cls = bundle?.principalClass ?? NSClassFromString("TweaksMediaReader")
        guard let cls else { cache.gaveUp = true; return nil }
        cache.reader = cls
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
