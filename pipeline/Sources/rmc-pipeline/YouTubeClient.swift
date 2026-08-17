import Foundation

enum YouTubeClientError: Error {
    case missingAPIKey
    case badStatus(Int, String)
    case channelNotFound
    case unexpectedResponseShape
}

struct YouTubeVideoItem {
    let videoId: String
    let title: String
    let publishedAt: String
    let thumbnailURL: String
}

/// Talks to the YouTube Data API v3 to list the show's channel uploads for `sync-videos`.
///
/// Deliberately uses `playlistItems.list` against the channel's "uploads" playlist rather
/// than `search.list` -- `search.list` costs ~100 quota units per call, while
/// `channels.list`/`playlistItems.list`/`videos.list` all cost 1 unit per call regardless
/// of `part`. A full sync of a ~250-video channel this way costs roughly a dozen quota
/// units total, trivial against the default 10,000/day quota -- so there's no need for an
/// incremental `--since` cursor the way `generate-trivia` has; a full re-list every run is
/// cheap, and upserting by video id (see `Video.swift`) makes it idempotent regardless.
struct YouTubeClient {
    private let apiKey: String
    private let session = URLSession.shared
    private static let base = "https://www.googleapis.com/youtube/v3"

    init() throws {
        guard let key = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"], !key.isEmpty else {
            throw YouTubeClientError.missingAPIKey
        }
        apiKey = key
    }

    /// Resolves a channel handle (e.g. "@RetroMacCast") to its "uploads" playlist id
    /// (`contentDetails.relatedPlaylists.uploads`) via one `channels.list` call.
    func fetchUploadsPlaylistId(handle: String) async throws -> String {
        let cleanHandle = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        var components = URLComponents(string: "\(Self.base)/channels")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "forHandle", value: cleanHandle),
            URLQueryItem(name: "key", value: apiKey),
        ]
        let json = try await get(components.url!)
        guard let items = json["items"] as? [[String: Any]], let first = items.first,
              let contentDetails = first["contentDetails"] as? [String: Any],
              let related = contentDetails["relatedPlaylists"] as? [String: Any],
              let uploads = related["uploads"] as? String else {
            throw YouTubeClientError.channelNotFound
        }
        return uploads
    }

    /// Pages through `playlistItems.list` (50/page) until either the playlist is exhausted
    /// or `limit` items have been collected (0 = no limit) -- capped during pagination
    /// itself, not just on the result array, so `--limit` genuinely bounds API calls for a
    /// cheap test run rather than fetching everything and then truncating.
    func fetchAllPlaylistItems(playlistId: String, limit: Int) async throws -> [YouTubeVideoItem] {
        var results: [YouTubeVideoItem] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "\(Self.base)/playlistItems")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "playlistId", value: playlistId),
                URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "key", value: apiKey),
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems

            let json = try await get(components.url!)
            guard let items = json["items"] as? [[String: Any]] else {
                throw YouTubeClientError.unexpectedResponseShape
            }
            for item in items {
                guard let snippet = item["snippet"] as? [String: Any],
                      let resourceId = snippet["resourceId"] as? [String: Any],
                      let videoId = resourceId["videoId"] as? String,
                      let title = snippet["title"] as? String,
                      let publishedAt = snippet["publishedAt"] as? String else { continue }
                let thumbnails = snippet["thumbnails"] as? [String: Any]
                let medium = thumbnails?["medium"] as? [String: Any]
                let thumbnailURL = (medium?["url"] as? String)
                    ?? "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg" // always-resolvable fallback
                results.append(YouTubeVideoItem(videoId: videoId, title: title, publishedAt: publishedAt, thumbnailURL: thumbnailURL))
                if limit > 0 && results.count >= limit { return results }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return results
    }

    /// `videos.list`, batched 50 ids/call, for `contentDetails.duration` -- `playlistItems.list`
    /// doesn't carry duration at all, so this is a separate pass.
    func fetchDurations(videoIds: [String]) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        let batches = stride(from: 0, to: videoIds.count, by: 50).map { Array(videoIds[$0..<min($0 + 50, videoIds.count)]) }
        for batch in batches {
            var components = URLComponents(string: "\(Self.base)/videos")!
            components.queryItems = [
                URLQueryItem(name: "part", value: "contentDetails"),
                URLQueryItem(name: "id", value: batch.joined(separator: ",")),
                URLQueryItem(name: "key", value: apiKey),
            ]
            let json = try await get(components.url!)
            guard let items = json["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let id = item["id"] as? String,
                      let contentDetails = item["contentDetails"] as? [String: Any],
                      let duration = contentDetails["duration"] as? String,
                      let seconds = Self.parseISO8601Duration(duration) else { continue }
                result[id] = seconds
            }
        }
        return result
    }

    private func get(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YouTubeClientError.badStatus(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeClientError.unexpectedResponseShape
        }
        return json
    }

    /// Foundation's `ISO8601DateFormatter` only parses dates, not durations -- YouTube
    /// returns duration as an ISO8601 duration string like "PT1H2M3S". A small manual scan
    /// is simpler and more predictable here than reaching for a regex for three optional
    /// numeric groups.
    static func parseISO8601Duration(_ value: String) -> Int? {
        guard value.hasPrefix("PT") else { return nil }
        var hours = 0, minutes = 0, seconds = 0
        var numberBuffer = ""
        for char in value.dropFirst(2) {
            if char.isNumber {
                numberBuffer.append(char)
            } else {
                let n = Int(numberBuffer) ?? 0
                switch char {
                case "H": hours = n
                case "M": minutes = n
                case "S": seconds = n
                default: break
                }
                numberBuffer = ""
            }
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Best-effort episode-number extraction from a video title, e.g. "RetroMacCast Episode
    /// 144 Part 1 of 3" or "RMC Episode 100" both resolve to 144/100. A title with no
    /// "Episode N" shape (bonus footage, vintage ephemera, live streams) returns nil and
    /// stays unlinked -- in the app, that's exactly the signal used to sort a video into
    /// "Bonus & Extras" instead of "Episode Recordings". Two videos matching the same
    /// number (a multi-part episode) is expected and fine -- episodeId isn't unique here.
    static func extractEpisodeNumber(fromTitle title: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?:RetroMacCast|RMC)\\s+Episode\\s+(\\d+)", options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: title) else {
            return nil
        }
        return Int(title[numberRange])
    }
}
