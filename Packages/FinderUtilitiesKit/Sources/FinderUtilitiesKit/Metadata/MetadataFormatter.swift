import Foundation

/// Turns metadata into menu lines. Pure; field order is the single place to change the default set.
public enum MetadataField: String, Sendable, CaseIterable {
    case resolution, fileSize, frameRate, duration, codec, alpha, depthAndColor, audioChannels, dpi, modified, created

    public static let defaults: [MetadataField] = [.resolution, .fileSize, .frameRate, .duration, .codec, .alpha, .depthAndColor, .audioChannels, .dpi, .modified]
}

public struct MetadataFormatter: Sendable {
    public var fields: [MetadataField]
    public init(fields: [MetadataField] = MetadataField.defaults) { self.fields = fields }

    public func lines(for state: MetadataState) -> [String] {
        switch state {
        case .loading: return ["Loading…"]
        case .unavailable(let why): return [why]
        case .ready(let m):
            var out = fields.compactMap { line($0, m) }
            if m.isDataless { out.append("Online-only (not downloaded)") }
            return out.isEmpty ? ["No metadata"] : out
        }
    }

    /// One-line summary for the top level of the menu: frame size first, then fps, duration and size.
    /// Returns nil until metadata is ready (the menu then shows only the Inspect Media submenu).
    public func summary(for state: MetadataState) -> String? {
        guard case .ready(let m) = state, !m.isDataless || m.width != nil else { return nil }
        var parts: [String] = []
        if let w = m.width, let h = m.height { parts.append("\(w)×\(h)") }
        if let fps = m.frameRate { parts.append(Self.trimmed(fps) + " fps") }
        if let d = m.duration { parts.append(Self.duration(d)) }
        if let b = m.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func line(_ f: MetadataField, _ m: MediaMetadata) -> String? {
        switch f {
        case .duration: return m.duration.map { "Duration: " + Self.duration($0) }
        case .resolution:
            guard let w = m.width, let h = m.height else { return nil }
            return "Resolution: \(w)×\(h)"
        case .frameRate: return m.frameRate.map { "Frame rate: " + Self.trimmed($0) + " fps" }
        case .codec: return m.codec.map { "Codec: " + $0 }
        case .fileSize: return m.fileSize.map { "Size: " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        case .alpha: return m.hasAlpha.map { "Alpha: " + ($0 ? "Yes" : "No") }
        case .depthAndColor:
            let parts = [m.bitDepth.map { "\($0)-bit" }, m.colorSpace].compactMap { $0 }
            return parts.isEmpty ? nil : "Color: " + parts.joined(separator: ", ")
        case .dpi: return m.dpi.map { "DPI: " + Self.trimmed($0) }
        case .audioChannels: return m.audioChannels.map { "Audio: \($0) ch" } ?? (m.duration != nil ? "Audio: none" : nil)
        case .modified: return m.modified.map { "Modified: " + $0.formatted(date: .abbreviated, time: .shortened) }
        case .created: return m.created.map { "Created: " + $0.formatted(date: .abbreviated, time: .shortened) }
        }
    }

    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        let (h, m, sec) = (t / 3600, t % 3600 / 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func trimmed(_ d: Double) -> String {
        let r = (d * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}
