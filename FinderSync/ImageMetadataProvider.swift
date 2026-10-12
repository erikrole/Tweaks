import Foundation
import FinderUtilitiesKit
import ImageIO

/// Still-image facts via ImageIO (header only; does not decode pixels).
struct ImageMetadataProvider: MetadataProvider {
    func metadata(for url: URL) async throws -> MediaMetadata {
        var out = MediaMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return out }
        if let w = props[kCGImagePropertyPixelWidth] as? Int { out.width = w }
        if let h = props[kCGImagePropertyPixelHeight] as? Int { out.height = h }
        out.hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool
        out.bitDepth = props[kCGImagePropertyDepth] as? Int
        out.colorSpace = props[kCGImagePropertyColorModel] as? String
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double { out.dpi = dpi }
        return out
    }
}
