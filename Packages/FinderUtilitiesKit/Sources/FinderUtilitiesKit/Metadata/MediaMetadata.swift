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
