import AVFoundation
import FinderUtilitiesKit

/// Container and track facts via AVFoundation. Runs only under `MetadataService`'s deadline and
/// circuit breaker, and never on cloud placeholders (the service skips non-first providers).
struct AVMetadataProvider: MetadataProvider {
    func metadata(for url: URL) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var out = MediaMetadata()
        guard let playable = try? await asset.load(.isPlayable), playable else { return out }

        if let d = try? await asset.load(.duration), d.isNumeric { out.duration = d.seconds }
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await video.load(.naturalSize) {
                out.width = Int(size.width.rounded())
                out.height = Int(size.height.rounded())
            }
            if let fps = try? await video.load(.nominalFrameRate), fps > 0 { out.frameRate = Double(fps) }
            if let desc = try? await video.load(.formatDescriptions).first {
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                out.codec = Self.codecName(sub)
                out.hasAlpha = sub == kCMVideoCodecType_AppleProRes4444 || sub == kCMVideoCodecType_AppleProRes4444XQ
                let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
                if let bits = ext?["BitsPerComponent"] as? Int { out.bitDepth = bits }
                if let prim = ext?[kCVImageBufferColorPrimariesKey as String] as? String {
                    out.colorSpace = Self.primaries(prim)
                }
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let desc = try? await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            out.audioChannels = Int(asbd.pointee.mChannelsPerFrame)
        }
        return out
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
}
