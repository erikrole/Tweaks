import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Loaded by the Finder Sync extension only when Inspect Media actually reads a file.
/// Keeping AVFoundation and ImageIO out of the extension binary is what holds its idle
/// memory down; once this bundle is mapped, those frameworks stay mapped until Finder
/// quits the extension.
@objc(TweaksMediaReader)
public final class TweaksMediaReader: NSObject {
    /// Synchronous on purpose: the extension calls it from a GCD queue, and this waits
    /// on that queue (not on a Swift concurrency thread) while the async reads finish.
    @objc(factsForPath:)
    public static func facts(forPath path: String) -> NSDictionary {
        let box = Box()
        box.enter()
        Task {
            box.finish(await collect(URL(filePath: path)))
        }
        // Bound a hung share. MetadataService already abandons the caller; this lets the
        // GCD thread go back to the pool instead of waiting on AVFoundation forever.
        return box.wait()
    }

    /// Image facts overwrite video facts when both exist, matching the old provider order
    /// (AVFoundation, then ImageIO).
    private static func collect(_ url: URL) async -> NSDictionary {
        var facts: [String: Any] = [:]
        merge(await videoFacts(url), into: &facts)
        merge(imageFacts(url), into: &facts)
        let dict = NSMutableDictionary()
        for (key, value) in facts { dict[key] = value }
        return dict
    }

    private static func merge(_ incoming: [String: Any], into facts: inout [String: Any]) {
        for (key, value) in incoming {
            facts[key] = value
        }
    }

    private static func imageFacts(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var facts: [String: Any] = [:]
        if let w = int(props[kCGImagePropertyPixelWidth]) { facts["width"] = w }
        if let h = int(props[kCGImagePropertyPixelHeight]) { facts["height"] = h }
        if let alpha = bool(props[kCGImagePropertyHasAlpha]) { facts["hasAlpha"] = alpha }
        if let depth = int(props[kCGImagePropertyDepth]) { facts["bitDepth"] = depth }
        if let color = props[kCGImagePropertyColorModel] as? String { facts["colorSpace"] = color }
        if let dpi = double(props[kCGImagePropertyDPIWidth]) { facts["dpi"] = dpi }
        return facts
    }

    private static func videoFacts(_ url: URL) async -> [String: Any] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let playable = try? await asset.load(.isPlayable), playable else { return [:] }
        var facts: [String: Any] = [:]
        if let duration = try? await asset.load(.duration), duration.isNumeric { facts["duration"] = duration.seconds }
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await video.load(.naturalSize) {
                facts["width"] = Int(size.width.rounded())
                facts["height"] = Int(size.height.rounded())
            }
            if let fps = try? await video.load(.nominalFrameRate), fps > 0 { facts["frameRate"] = Double(fps) }
            if let desc = try? await video.load(.formatDescriptions).first {
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                facts["codec"] = codecName(sub)
                facts["hasAlpha"] = sub == kCMVideoCodecType_AppleProRes4444 || sub == kCMVideoCodecType_AppleProRes4444XQ
                let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
                if let bits = ext?["BitsPerComponent"] as? Int { facts["bitDepth"] = bits }
                if let prim = ext?[kCVImageBufferColorPrimariesKey as String] as? String {
                    facts["colorSpace"] = primaries(prim)
                }
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let desc = try? await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            facts["audioChannels"] = Int(asbd.pointee.mChannelsPerFrame)
        }
        return facts
    }

    private static func primaries(_ p: String) -> String {
        switch p {
        case "ITU_R_709_2": return "Rec. 709"
        case "ITU_R_2020": return "Rec. 2020"
        case "P3_D65", "DCI_P3": return "P3"
        case "EBU_3213": return "EBU"
        default: return p
        }
    }

    private static func codecName(_ type: FourCharCode) -> String {
        switch type {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kCMVideoCodecType_JPEG: return "JPEG"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((type >> $0) & 0xFF) }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    /// ImageIO hands numbers back as NSNumber, which `as? Int` does not accept.
    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    /// DispatchGroup is captured only here, so the unstructured task stays Sendable.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var dict: NSDictionary = [:]

        func enter() { group.enter() }

        func finish(_ value: NSDictionary) {
            lock.lock()
            dict = value
            lock.unlock()
            group.leave()
        }

        func wait() -> NSDictionary {
            _ = group.wait(timeout: .now() + 6)
            lock.lock()
            defer { lock.unlock() }
            return dict
        }
    }
}
