import Foundation
import SwiftSoup

public struct LibsynCrawler {
    public static let baseURL = "https://retromaccast.libsyn.com"

    public init() {}

    public func fetchMonthPage(year: Int, month: Int) async throws -> [Episode] {
        let urlString = "\(Self.baseURL)/\(year)/\(String(format: "%02d", month))"
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (compatible; RMCArchiveBot/0.1; personal fan project)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.fetchWithRetry(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return try parseMonthPage(html: html)
    }

    func parseMonthPage(html: String) throws -> [Episode] {
        let doc = try SwiftSoup.parse(html)
        let items = try doc.select("div.libsyn-item[data-id]")
        var episodes: [Episode] = []
        for item in items.array() {
            guard let idString = try? item.attr("data-id"), let id = Int(idString) else { continue }
            // Text-only posts (e.g. "Podcast Alley") have no audio iframe -- skip them.
            guard let iframes = try? item.select("iframe"), !iframes.isEmpty() else { continue }
            guard let titleAnchor = try item.select("h2.section-heading a").first() else { continue }
            let title = try titleAnchor.text()
            let pageURL = try titleAnchor.attr("href")
            let dateText = try? item.select("p.date").first()?.text()
            let pubDate = Self.isoDate(from: dateText ?? "") ?? ""
            let showNotesHTML = (try? item.select("p.lead").first()?.html()) ?? ""
            let episodeNumber = Self.episodeNumber(from: title)
            episodes.append(Episode(
                id: id,
                episodeNumber: episodeNumber,
                title: title,
                pageURL: pageURL,
                pubDate: pubDate,
                showNotesHTML: showNotesHTML
            ))
        }
        return episodes
    }

    public func resolveAudioURL(itemId: Int) async throws -> String? {
        let embedURLString = "https://html5-player.libsyn.com/embed/episode/id/\(itemId)/height/90/theme/custom/thumbnail/yes/direction/forward/render-playlist/no/custom-color/000000/"
        guard let url = URL(string: embedURLString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (compatible; RMCArchiveBot/0.1; personal fan project)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await Self.fetchWithRetry(request)
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        // The embed page's `data-url` attribute is unreliable -- for many episodes it points
        // at the episode's webpage rather than the audio file. The `playlistItem` JS object
        // embedded in the page always has the real, CDN-backed media URL, so use that instead.
        guard let markerRange = html.range(of: "\"media_url\":\"") else { return nil }
        let afterMarker = html[markerRange.upperBound...]
        guard let endQuote = afterMarker.firstIndex(of: "\"") else { return nil }
        return String(afterMarker[..<endQuote]).replacingOccurrences(of: "\\/", with: "/")
    }

    static func episodeNumber(from title: String) -> Int? {
        // Titles look like "Episode 206: Premature Specification"
        guard let range = title.range(of: #"Episode\s+(\d+)"#, options: .regularExpression) else { return nil }
        let matched = String(title[range])
        let digits = matched.filter(\.isNumber)
        return Int(digits)
    }

    static func isoDate(from text: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.locale = Locale(identifier: "en_US_POSIX")
        return iso.string(from: date)
    }

    /// Retries transient network failures with a short linear backoff instead of letting one
    /// slow response kill the whole run -- confirmed in production: a single request to
    /// `retromaccast.libsyn.com/2006/12` timed out mid-`crawl-index`, which took down the
    /// entire GitHub Actions job (and every month after it that would otherwise have succeeded)
    /// since there was previously no retry at all. A 30s per-attempt timeout (well under
    /// URLRequest's 60s default) means a genuinely hung request gets retried instead of eating
    /// most of a minute before anything even happens -- sized off directly-measured real
    /// response times from Libsyn (6.5s-14.8s, right up against a tighter 20s attempt), not
    /// guessed, since this site runs slow enough on its own that too tight a per-attempt budget
    /// would just turn "slow" into "spuriously retried" instead of actually fixing anything.
    ///
    /// Only retries errors that actually look transient (timeout, connection lost/reset, DNS
    /// hiccups, host unreachable) -- a real 404 or malformed-URL failure isn't going to fix
    /// itself by waiting, so those still fail immediately rather than spinning for no reason.
    static func fetchWithRetry(_ request: URLRequest, maxAttempts: Int = 3) async throws -> (Data, URLResponse) {
        var attemptRequest = request
        if attemptRequest.timeoutInterval == 60 { // URLRequest's unmodified default
            attemptRequest.timeoutInterval = 30
        }
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await URLSession.shared.data(for: attemptRequest)
            } catch {
                lastError = error
                guard isTransient(error), attempt < maxAttempts else { throw error }
                let backoffSeconds = Double(attempt) * 2 // 2s, then 4s
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private static func isTransient(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }
}
