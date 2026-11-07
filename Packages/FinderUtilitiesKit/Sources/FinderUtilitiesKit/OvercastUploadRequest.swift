import Foundation

/// A Finder request opens a review window. Only the window's Upload button may
/// authorize sending bytes: any website can invoke a custom URL scheme.
public enum OvercastUploadRequest {
    public static let extensions: Set<String> = ["mp3", "m4a"]
    public static let maximumFiles = 20

    public static func url(for files: [URL]) -> URL? {
        guard !files.isEmpty, files.count <= maximumFiles,
              files.allSatisfy({ $0.isFileURL && !$0.hasDirectoryPath && extensions.contains($0.pathExtension.lowercased()) }) else { return nil }
        var parts = URLComponents()
        parts.scheme = "tweaks"
        parts.host = "overcast"
        parts.queryItems = files.map { URLQueryItem(name: "file", value: $0.path) }
        guard let url = parts.url, self.files(from: url) != nil else { return nil }
        return url
    }

    public static func files(from url: URL) -> [URL]? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "tweaks", parts.host == "overcast", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let query = parts.queryItems, !query.isEmpty, query.count <= maximumFiles else { return nil }
        var result: [URL] = []
        var seen: Set<String> = []
        for item in query {
            guard item.name == "file", let path = item.value, path.hasPrefix("/"),
                  !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
            let file = URL(fileURLWithPath: path).standardizedFileURL
            guard extensions.contains(file.pathExtension.lowercased()), seen.insert(file.path).inserted else { return nil }
            result.append(file)
        }
        return result
    }
}
