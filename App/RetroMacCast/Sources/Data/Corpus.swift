import Foundation
import GRDB
import RMCCore

enum SearchSortOrder: String, CaseIterable, Identifiable {
    case relevance = "Relevance"
    case date = "Date"
    var id: String { rawValue }
}

final class Corpus {
    /// `var`, not `let` -- `reloadFromDisk()` reassigns this once a newer corpus has been
    /// downloaded and validated, so every existing `Corpus.shared.search(...)`-style call
    /// site picks up the new data on its very next call, with no DI plumbing needed anywhere
    /// else in the app.
    static var shared = Corpus()

    let dbQueue: DatabaseQueue

    /// Where `CorpusUpdateManager` downloads a newer corpus to -- checked first at launch
    /// (and after `reloadFromDisk()`), falling back to the bundled copy shipped with the app
    /// when nothing's been downloaded yet.
    static let downloadedDBURL: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RetroMacCast", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent("rmc.sqlite")
    }()

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

    struct OnThisDayResult {
        /// True when at least one episode aired on today's exact calendar date (any year).
        /// False means `episodes` is the wider +/-3-day fallback window instead.
        let isExactMatch: Bool
        let episodes: [Episode]
    }

    struct CollectionItemResult: Identifiable {
        let id: Int64
        let episode: Episode
        let blurb: String
        let timestampMs: Int?
        let contextStartMs: Int?
        let contextEndMs: Int?
    }

    struct TriviaResult: Identifiable {
        let id: Int64
        let factText: String
        /// nil for a cross-episode aggregate fact that isn't tied to one moment -- the view
        /// only shows a play button when this is set.
        let episode: Episode?
        let timestampMs: Int?
        let contextStartMs: Int?
        let contextEndMs: Int?
    }

    struct TriviaSelection {
        let featured: TriviaResult
        /// A small random slice of the rest of the catalog -- deliberately capped (not the
        /// whole catalog) so it reads as a handful of fun facts at a glance, not a wall of
        /// text to scroll through.
        let more: [TriviaResult]
    }

    private init() {
        let path: String
        if FileManager.default.fileExists(atPath: Self.downloadedDBURL.path) {
            path = Self.downloadedDBURL.path
        } else if let bundled = Bundle.main.path(forResource: "rmc", ofType: "sqlite") {
            path = bundled
        } else {
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

    /// Called after `CorpusUpdateManager` finishes downloading and validating a newer
    /// database.
    static func reloadFromDisk() {
        shared = Corpus()
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

                return try episodes.map { episode in
                    let segment = try Self.findMatchingSegment(db, episodeId: episode.id, query: trimmed)

                    let (contextStartMs, contextEndMs) = try Self.contextWindow(db, episodeId: episode.id, segment: segment)

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

    /// Episodes that aired on today's calendar date in any year ("11 years ago today...").
    /// Falls back to a +/-3-day window ("this week in history") on the ~13% of days with
    /// no exact match -- the show's roughly-weekly cadence over 20 years means many dates
    /// still land empty, but rarely a whole week does.
    func onThisDay(referenceDate: Date = Date()) -> OnThisDayResult {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"

        let todayString = formatter.string(from: referenceDate)
        var windowDays: Set<String> = []
        for offset in -3...3 {
            if let date = calendar.date(byAdding: .day, value: offset, to: referenceDate) {
                windowDays.insert(formatter.string(from: date))
            }
        }

        do {
            return try dbQueue.read { db in
                let days = Array(windowDays)
                let placeholders = days.map { _ in "?" }.joined(separator: ",")
                let episodes = try Episode.fetchAll(db, sql: """
                    SELECT * FROM episodes
                    WHERE substr(pubDate, 6, 5) IN (\(placeholders))
                    ORDER BY pubDate DESC
                    """, arguments: StatementArguments(days))

                let exact = episodes.filter { Self.monthDay($0.pubDate) == todayString }
                if !exact.isEmpty {
                    return OnThisDayResult(isExactMatch: true, episodes: exact)
                }
                return OnThisDayResult(isExactMatch: false, episodes: episodes)
            }
        } catch {
            print("onThisDay error: \(error)")
            return OnThisDayResult(isExactMatch: false, episodes: [])
        }
    }

    /// Days between the earliest episode's air date and today, for the "keeping it retro
    /// for N days and counting" tagline.
    func daysSinceFirstEpisode(referenceDate: Date = Date()) -> Int? {
        do {
            return try dbQueue.read { db in
                guard let earliest = try String.fetchOne(db, sql: "SELECT MIN(pubDate) FROM episodes"),
                      earliest.count == 10 else { return nil }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(identifier: "UTC")
                guard let earliestDate = formatter.date(from: earliest) else { return nil }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                return calendar.dateComponents([.day], from: earliestDate, to: referenceDate).day
            }
        } catch {
            print("daysSinceFirstEpisode error: \(error)")
            return nil
        }
    }

    /// Picks a fresh, genuinely random selection from the trivia catalog -- one featured fact
    /// plus a small slice of others, capped at `moreCount` rather than the whole catalog so it
    /// reads as a handful of fun facts at a glance instead of a long list to scroll through.
    /// Called once when the Trivia tab first appears (so it's different each app launch) and
    /// again on demand from its Refresh button -- unlike `onThisDay`'s stable-per-day rotation,
    /// there's no reason for this one to be deterministic, so it's just a true shuffle.
    func randomTriviaSelection(moreCount: Int = 6) -> TriviaSelection? {
        do {
            return try dbQueue.read { db in
                let facts = try TriviaFact.fetchAll(db, sql: "SELECT * FROM trivia_facts")
                guard !facts.isEmpty else { return nil }

                let shuffled = facts.shuffled()
                let picked = Array(shuffled.prefix(1 + moreCount))
                let results = try picked.map { try Self.triviaResult(db, fact: $0) }

                return TriviaSelection(featured: results[0], more: Array(results.dropFirst()))
            }
        } catch {
            print("randomTriviaSelection error: \(error)")
            return nil
        }
    }

    private static func triviaResult(_ db: Database, fact: TriviaFact) throws -> TriviaResult {
        guard let episodeId = fact.episodeId else {
            return TriviaResult(id: fact.id ?? 0, factText: fact.factText, episode: nil, timestampMs: nil, contextStartMs: nil, contextEndMs: nil)
        }

        if let segmentId = fact.segmentId {
            let segment = try TranscriptSegment.fetchOne(db, sql: "SELECT * FROM transcript_segments WHERE id = ?", arguments: [segmentId])
            // segmentId set but no longer resolves -- its transcript_segment row was deleted
            // out from under it (e.g. a later re-transcription/reclassification pass), even
            // though episodeId's own onDelete: .setNull left episodeId itself intact. Rather
            // than fall through to contextWindow(segment: nil) below and silently play from
            // 0:00 as if that were always the plan, treat the whole fact as unlinked -- we can
            // no longer verify what moment it was pointing at, so no play button is more honest
            // than a wrong one.
            guard let segment else {
                return TriviaResult(id: fact.id ?? 0, factText: fact.factText, episode: nil, timestampMs: nil, contextStartMs: nil, contextEndMs: nil)
            }
            let episode = try Episode.fetchOne(db, sql: "SELECT * FROM episodes WHERE id = ?", arguments: [episodeId])
            let (contextStartMs, contextEndMs) = try contextWindow(db, episodeId: episodeId, segment: segment)
            return TriviaResult(id: fact.id ?? 0, factText: fact.factText, episode: episode, timestampMs: fact.timestampMs, contextStartMs: contextStartMs, contextEndMs: contextEndMs)
        }

        // No segmentId at all -- an aggregate-leaning fact that was always episode-only, never
        // moment-specific. Playing from 0:00 is the right fallback here, same as elsewhere in
        // the app (e.g. MuseumMomentCard) when a collection item has no segment.
        let episode = try Episode.fetchOne(db, sql: "SELECT * FROM episodes WHERE id = ?", arguments: [episodeId])
        let (contextStartMs, contextEndMs) = try contextWindow(db, episodeId: episodeId, segment: nil)
        return TriviaResult(id: fact.id ?? 0, factText: fact.factText, episode: episode, timestampMs: fact.timestampMs, contextStartMs: contextStartMs, contextEndMs: contextEndMs)
    }

    private static func monthDay(_ pubDate: String) -> String {
        guard pubDate.count == 10 else { return "" }
        return String(pubDate.dropFirst(5).prefix(5))
    }

    func listCollections() -> [EpisodeCollection] {
        do {
            return try dbQueue.read { db in
                try EpisodeCollection.fetchAll(db, sql: "SELECT * FROM collections ORDER BY kind, title")
            }
        } catch {
            print("listCollections error: \(error)")
            return []
        }
    }

    func items(forCollection collectionId: Int64) -> [CollectionItemResult] {
        do {
            return try dbQueue.read { db in
                let items = try CollectionItem.fetchAll(db, sql: """
                    SELECT * FROM collection_items WHERE collectionId = ?
                    """, arguments: [collectionId])
                return try items.compactMap { item -> CollectionItemResult? in
                    guard let id = item.id,
                          let episode = try Episode.fetchOne(db, sql: "SELECT * FROM episodes WHERE id = ?", arguments: [item.episodeId])
                    else { return nil }

                    var segment: TranscriptSegment?
                    if let segmentId = item.segmentId {
                        segment = try TranscriptSegment.fetchOne(db, sql: "SELECT * FROM transcript_segments WHERE id = ?", arguments: [segmentId])
                    }
                    let (contextStartMs, contextEndMs) = try Self.contextWindow(db, episodeId: item.episodeId, segment: segment)

                    return CollectionItemResult(
                        id: id,
                        episode: episode,
                        blurb: item.blurb,
                        timestampMs: item.timestampMs,
                        contextStartMs: contextStartMs,
                        contextEndMs: contextEndMs
                    )
                }
            }
        } catch {
            print("items(forCollection:) error: \(error)")
            return []
        }
    }

    /// Where "play in context" should start/stop -- one segment of padding on either side
    /// of the match, falling back to the match's own bounds when there's no neighboring
    /// segment (start/end of episode), or to "play from 0:00" when there's no segment at
    /// all (a title/show-notes-only match, or a collection item the model tagged without
    /// a locatable verbatim quote).
    private static func contextWindow(_ db: Database, episodeId: Int, segment: TranscriptSegment?) throws -> (Int?, Int?) {
        guard let segment else { return (0, nil) }

        // A fixed, short lead-in/lead-out rather than the full neighboring segment --
        // whisper's segments are pause-based, not sentence-based, and can run 5-20+
        // seconds, which made the clip feel loosely framed around the actual match.
        // This clamps to the neighbor's own bounds so it never reaches past it into
        // the segment beyond that.
        let padding = 2500
        let prev = try TranscriptSegment.fetchOne(db, sql: """
            SELECT * FROM transcript_segments
            WHERE episodeId = ? AND startMs < ?
            ORDER BY startMs DESC LIMIT 1
            """, arguments: [episodeId, segment.startMs])
        let next = try TranscriptSegment.fetchOne(db, sql: """
            SELECT * FROM transcript_segments
            WHERE episodeId = ? AND startMs > ?
            ORDER BY startMs ASC LIMIT 1
            """, arguments: [episodeId, segment.startMs])
        let contextStartMs = max(segment.startMs - padding, prev?.startMs ?? 0)
        let contextEndMs = min(segment.endMs + padding, next?.endMs ?? segment.endMs)
        return (contextStartMs, contextEndMs)
    }

    private static func sanitizeForFTS(_ query: String) -> String {
        let tokens = query.split(separator: " ").map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "")
            return "\"\(escaped)\""
        }
        guard tokens.count > 1 else { return tokens.first ?? "" }
        // A bare "a" "b" "c" query is an implicit AND across the *whole* transcript --
        // satisfied even when the words never appear together (e.g. "Power" from one
        // aside, "7200" from an unrelated RPM figure minutes later). NEAR requires the
        // terms to actually cluster, which is both a better relevance signal and what
        // makes findMatchingSegment(...) below able to locate a real snippet afterward.
        return "NEAR(\(tokens.joined(separator: " ")), 15)"
    }

    /// Locates a transcript segment to use as the result's snippet/timestamp. Tries an
    /// exact verbatim match first (the tightest, most relevant snippet), then falls back
    /// to a segment containing every query word in any order -- Whisper's pause-based
    /// segmentation means a multi-word query often isn't verbatim-contiguous in any one
    /// segment even when the episode is a genuine, on-topic match.
    private static func findMatchingSegment(_ db: Database, episodeId: Int, query: String) throws -> TranscriptSegment? {
        if let exact = try TranscriptSegment.fetchOne(db, sql: """
            SELECT * FROM transcript_segments
            WHERE episodeId = ? AND text LIKE ? COLLATE NOCASE
            LIMIT 1
            """, arguments: [episodeId, "%\(query)%"]) {
            return exact
        }

        let words: [String] = query.split(separator: " ").filter { $0.count > 1 }.map(String.init)
        guard !words.isEmpty else { return nil }
        var sql = "SELECT * FROM transcript_segments WHERE episodeId = ?"
        var arguments: [DatabaseValueConvertible] = [episodeId]
        for word in words {
            sql += " AND text LIKE ? COLLATE NOCASE"
            arguments.append("%\(word)%")
        }
        sql += " LIMIT 1"
        if let sameSegment = try TranscriptSegment.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) {
            return sameSegment
        }

        // Last resort: the phrase itself straddles a segment cut mid-sentence (Whisper
        // segments are pause-based, not sentence-based) -- e.g. "...a Power Mac" ends one
        // segment and "7200 running..." starts the next. Check adjacent pairs and anchor
        // on the earlier one so playback starts right before the match.
        let all = try TranscriptSegment.fetchAll(db, sql: """
            SELECT * FROM transcript_segments WHERE episodeId = ? ORDER BY startMs
            """, arguments: [episodeId])
        let lowerWords = words.map { $0.lowercased() }
        for i in 0..<max(0, all.count - 1) {
            let combined = (all[i].text + " " + all[i + 1].text).lowercased()
            if lowerWords.allSatisfy({ combined.contains($0) }) {
                return all[i]
            }
        }
        return nil
    }
}
