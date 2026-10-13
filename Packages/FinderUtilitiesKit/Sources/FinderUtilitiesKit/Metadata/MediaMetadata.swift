import Foundation

/// Quick-look facts about one file. Every field is optional: providers fill what they can.
public struct MediaMetadata: Sendable, Equatable {
    public var fileSize: Int64?
    public var created: Date?
    public var modified: Date?
    public var duration: TimeInterval?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var codec: String?
    public var audioChannels: Int?
    public var hasAlpha: Bool?
    public var bitDepth: Int?
    public var colorSpace: String?
    public var dpi: Double?
    /// True for cloud placeholders (Box, Drive, iCloud online-only). Content fields stay nil.
    public var isDataless = false

    public init() {}

    /// Merges non-nil fields of `other` into self.
    public mutating func merge(_ other: MediaMetadata) {
        fileSize = other.fileSize ?? fileSize
        created = other.created ?? created
        modified = other.modified ?? modified
        duration = other.duration ?? duration
        width = other.width ?? width
        height = other.height ?? height
        frameRate = other.frameRate ?? frameRate
        codec = other.codec ?? codec
        audioChannels = other.audioChannels ?? audioChannels
        hasAlpha = other.hasAlpha ?? hasAlpha
        bitDepth = other.bitDepth ?? bitDepth
        colorSpace = other.colorSpace ?? colorSpace
        dpi = other.dpi ?? dpi
        isDataless = isDataless || other.isDataless
    }
}

/// Reads metadata for one file. May block on I/O; always called off the main thread under a timeout.
public protocol MetadataProvider: Sendable {
    func metadata(for url: URL) async throws -> MediaMetadata
}

public enum MetadataFailure: Error, Sendable, Equatable {
    case timedOut
    case volumeCoolingDown
}

/// Facts a media reader (possibly loaded later, in another bundle) can hand back.
/// Missing keys are nil and must not wipe a value another provider already found.
public struct MediaFacts: Sendable, Equatable {
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var codec: String?
    public var audioChannels: Int?
    public var hasAlpha: Bool?
    public var bitDepth: Int?
    public var colorSpace: String?
    public var dpi: Double?

    public init(duration: Double? = nil, width: Int? = nil, height: Int? = nil, frameRate: Double? = nil,
                codec: String? = nil, audioChannels: Int? = nil, hasAlpha: Bool? = nil, bitDepth: Int? = nil,
                colorSpace: String? = nil, dpi: Double? = nil) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.audioChannels = audioChannels
        self.hasAlpha = hasAlpha
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
        self.dpi = dpi
    }

    /// Numbers may arrive as Int, Double, or NSNumber depending on who built the dictionary.
    public init(dictionary: [String: Any]) {
        duration = Self.double(dictionary["duration"])
        width = Self.int(dictionary["width"])
        height = Self.int(dictionary["height"])
        frameRate = Self.double(dictionary["frameRate"])
        codec = Self.text(dictionary["codec"])
        audioChannels = Self.int(dictionary["audioChannels"])
        hasAlpha = Self.bool(dictionary["hasAlpha"])
        bitDepth = Self.int(dictionary["bitDepth"])
        colorSpace = Self.text(dictionary["colorSpace"])
        dpi = Self.double(dictionary["dpi"])
    }

    public func apply(to metadata: inout MediaMetadata) {
        if let duration { metadata.duration = duration }
        if let width { metadata.width = width }
        if let height { metadata.height = height }
        if let frameRate { metadata.frameRate = frameRate }
        if let codec { metadata.codec = codec }
        if let audioChannels { metadata.audioChannels = audioChannels }
        if let hasAlpha { metadata.hasAlpha = hasAlpha }
        if let bitDepth { metadata.bitDepth = bitDepth }
        if let colorSpace { metadata.colorSpace = colorSpace }
        if let dpi { metadata.dpi = dpi }
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

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
}
