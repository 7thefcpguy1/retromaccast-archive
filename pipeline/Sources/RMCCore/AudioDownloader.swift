import Foundation

public enum AudioDownloaderError: Error {
    case badStatus(Int)
    case suspiciouslySmall(Int)
}

public struct AudioDownloader {
    public init() {}

    public func download(url: URL, to localPath: String) async throws {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (compatible; RMCArchiveBot/0.1; personal fan project)", forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AudioDownloaderError.badStatus(code)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? nil
        // A real episode is tens of MB; anything under 100KB is almost certainly an HTML
        // error page or a wrong (non-audio) URL, not audio -- fail fast with a clear reason
        // instead of letting ffmpeg choke on it later with an opaque exit code.
        if let size = size, size < 100_000 {
            throw AudioDownloaderError.suspiciouslySmall(size)
        }
        let destination = URL(fileURLWithPath: localPath)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
