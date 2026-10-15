import Foundation

/// Finder passes selection to the host for a visible review/export panel. A URL
/// request never authorizes an export and cannot select arbitrary destinations.
public enum ImageActionRequest {
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]
    public static let maximumFiles = 20

    public static func url(for files: [URL]) -> URL? {
        guard !files.isEmpty, files.count <= maximumFiles,
              files.allSatisfy({ $0.isFileURL && extensions.contains($0.pathExtension.lowercased()) }) else { return nil }
        var parts = URLComponents()
        parts.scheme = "tweaks"
        parts.host = "images"
        parts.queryItems = files.map { URLQueryItem(name: "file", value: $0.path) }
        return parts.url
    }

    public static func files(from url: URL) -> [URL]? {
        guard url.scheme == "tweaks", url.host == "images",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !query.isEmpty, query.count <= maximumFiles else { return nil }
        var result: [URL] = []
        for item in query {
            guard item.name == "file", let path = item.value, path.hasPrefix("/"),
                  !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
            let file = URL(fileURLWithPath: path)
            guard extensions.contains(file.pathExtension.lowercased()) else { return nil }
            result.append(file)
        }
        return result
    }
}
