import Foundation
import GRDB
import RMCCore

enum SearchSortOrder: String, CaseIterable, Identifiable {
    case relevance = "Relevance"
    case date = "Date"
    var id: String { rawValue }
}

final class Corpus {
    static let shared = Corpus()

    let dbQueue: DatabaseQueue

    struct SearchResult: Identifiable {
        let episode: Episode
        let snippet: String?
        let timestampMs: Int?
        /// Where "play in context" should start/stop -- one segment of padding on either
        /// side of the match, falling back to the match's own bounds when there's no
        /// neighboring segment (start/end of episode).
        let contextStartMs: Int?
        let contextEndMs: Int?
        var id: Int { episode.id }
    }

    private init() {
        guard let path = Bundle.main.path(forResource: "rmc", ofType: "sqlite") else {
            fatalError("rmc.sqlite not found in app bundle")
        }
        var config = Configuration()
        config.readonly = true
        do {
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        } catch {
            fatalError("Failed to open corpus: \(error)")
        }
    }

    func search(_ query: String, sortBy: SearchSortOrder = .relevance) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try dbQueue.read { db in
                let ftsQuery = Self.sanitizeForFTS(trimmed)
                // episodes_fts columns are (title, showNotesHTML, transcriptText) in that
                // order -- weight title/show-notes matches well above one-off transcript
                // mentions, since a deliberate title match is a much stronger signal than
                // a word said once in passing over a 40-minute episode.
                let orderClause = sortBy == .relevance
                    ? "ORDER BY bm25(episodes_fts, 10.0, 5.0, 1.0)"
                    : "ORDER BY episodes.pubDate DESC"
                let episodes = try Episode.fetchAll(db, sql: """
                    SELECT episodes.* FROM episodes_fts
                    JOIN episodes ON episodes.id = episodes_fts.rowid
                    WHERE episodes_fts MATCH ?
                    \(orderClause)
                    LIMIT 30
                    """, arguments: [ftsQuery])

                let likePattern = "%\(trimmed)%"
                return try episodes.map { episode in
                    let segment = try TranscriptSegment.fetchOne(db, sql: """
                        SELECT * FROM transcript_segments
                        WHERE episodeId = ? AND text LIKE ? COLLATE NOCASE
                        LIMIT 1
                        """, arguments: [episode.id, likePattern])

                    var contextStartMs = segment?.startMs
                    var contextEndMs = segment?.endMs
                    if let segment {
                        let prev = try TranscriptSegment.fetchOne(db, sql: """
                            SELECT * FROM transcript_segments
                            WHERE episodeId = ? AND startMs < ?
                            ORDER BY startMs DESC LIMIT 1
                            """, arguments: [episode.id, segment.startMs])
                        let next = try TranscriptSegment.fetchOne(db, sql: """
                            SELECT * FROM transcript_segments
                            WHERE episodeId = ? AND startMs > ?
                            ORDER BY startMs ASC LIMIT 1
                            """, arguments: [episode.id, segment.startMs])
                        contextStartMs = prev?.startMs ?? segment.startMs
                        contextEndMs = next?.endMs ?? segment.endMs
                    }

                    return SearchResult(
                        episode: episode,
                        snippet: segment?.text,
                        timestampMs: segment?.startMs,
                        contextStartMs: contextStartMs,
                        contextEndMs: contextEndMs
                    )
                }
            }
        } catch {
            print("search error: \(error)")
            return []
        }
    }

    private static func sanitizeForFTS(_ query: String) -> String {
        let tokens = query.split(separator: " ").map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "")
            return "\"\(escaped)\""
        }
        return tokens.joined(separator: " ")
    }
}
