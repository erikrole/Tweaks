import Foundation

/// Classifies a path by string only (no I/O) to pick a timeout and a circuit-breaker key.
public struct VolumeInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case local, network, cloud }
    public var key: String
    public var kind: Kind

    public static func classify(path: String) -> VolumeInfo {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.first == "Volumes", parts.count >= 2 {
            // Duplicate mounts ("name-1") share one breaker with the original.
            var name = parts[1]
            if let dash = name.lastIndex(of: "-"), Int(name[name.index(after: dash)...]) != nil {
                name = String(name[..<dash])
            }
            return VolumeInfo(key: "vol:" + name.lowercased(), kind: .network)
        }
        if let cs = parts.firstIndex(of: "CloudStorage"), cs > 0, parts[cs - 1] == "Library", cs + 1 < parts.count {
            return VolumeInfo(key: "cloud:" + parts[cs + 1], kind: .cloud)
        }
        if let md = parts.firstIndex(of: "Mobile Documents"), md > 0, parts[md - 1] == "Library" {
            return VolumeInfo(key: "cloud:icloud", kind: .cloud)
        }
        return VolumeInfo(key: "local", kind: .local)
    }
}
