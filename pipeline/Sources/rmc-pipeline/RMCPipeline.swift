import ArgumentParser
import Foundation
import GRDB
import RMCCore

let defaultDBPath = "corpus/rmc.sqlite"

let defaultPrompt = "Macintosh, Apple, RetroMacCast, James, John, Steve Jobs, Steve Wozniak, Woz, iPhone, iPod, iMac, iBook, PowerBook, PowerMac, Quadra, Performa, LC, SE, Plus, Classic, G3, G4, G5, System 7, Mac OS, eBay, KansasFest, MacWorld Expo, Vintage Computer Federation, VCF, AppleTalk, LocalTalk, SCSI, ADB, HyperCard, floppy disk, 68k, PowerPC, folklore.org"

@main
struct RMCPipeline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmc-pipeline",
        subcommands: [
            CrawlIndex.self, ResolveAudio.self, TranscribeBatch.self, Classify.self,
            ResetStaleSynthesis.self, Synthesize.self, GenerateTrivia.self, GenerateGlossary.self,
            ExportManifest.self, Stats.self, SyncVideos.self,
        ]
    )
}

struct CrawlIndex: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crawl-index",
        abstract: "Walk every monthly archive page and upsert episode metadata into the corpus DB."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var startYear: Int = 2006
    @Option(name: .long) var startMonth: Int = 12

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let crawler = LibsynCrawler()

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        var year = startYear
        var month = startMonth
        var totalFound = 0
        var monthsChecked = 0
        var monthsFailed: [String] = []

        while year < currentYear || (year == currentYear && month <= currentMonth) {
            // A single month's page failing (even after LibsynCrawler's own internal retries)
            // used to crash this whole command outright -- confirmed in production, a timeout
            // on just one month (out of 230+ walked from 2006 to now) took down the entire
            // `crawl-index` run and, with it, every downstream weekly-sync step (resolve-audio,
            // transcribe, classify, synthesize, sync-videos, the release) for months that would
            // otherwise have succeeded fine. Catching per-month and continuing means a bad
            // Libsyn day costs one missed month, not the whole week's sync.
            let episodes: [Episode]
            do {
                episodes = try await crawler.fetchMonthPage(year: year, month: month)
            } catch {
                let label = "\(year)-\(String(format: "%02d", month))"
                print("Warning: \(label) failed after retries (\(error.localizedDescription)) -- skipping, will retry next run.")
                monthsFailed.append(label)
                month += 1
                if month > 12 { month = 1; year += 1 }
                continue
            }
            monthsChecked += 1
            if !episodes.isEmpty {
                // INSERT OR IGNORE, not save() -- `ep` here is freshly built from the crawled
                // page and only carries the fields the crawler actually knows (title, pubDate,
                // showNotesHTML, ...). `save()` does a full-row upsert, so re-crawling a month
                // it already knew about was overwriting every existing episode's
                // transcriptText/transcriptStatus/classifiedAt back to their fresh-record
                // defaults -- silently wiping all downstream pipeline progress on every rerun.
                // `.ignore` makes this genuinely additive: a known episode id is left
                // completely untouched, only truly new episodes get inserted.
                let newCount = try await database.dbQueue.write { db -> Int in
                    var count = 0
                    for ep in episodes {
                        try ep.insert(db, onConflict: .ignore)
                        if db.changesCount > 0 {
                            count += 1
                        }
                    }
                    return count
                }
                totalFound += newCount
                if newCount > 0 {
                    print("\(year)-\(String(format: "%02d", month)): +\(newCount) new episodes (total \(totalFound))")
                }
            }

            month += 1
            if month > 12 {
                month = 1
                year += 1
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms politeness delay
        }

        let failureNote = monthsFailed.isEmpty ? "" : " (\(monthsFailed.count) months failed and will be retried next run: \(monthsFailed.joined(separator: ", ")))"
        print("Done. Checked \(monthsChecked) months, indexed \(totalFound) episodes into \(db)\(failureNote).")
    }
}

struct ResolveAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve-audio",
        abstract: "Resolve the direct traffic.libsyn.com audio URL for episodes that don't have one yet."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var limit: Int = 0 // 0 = no limit

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let crawler = LibsynCrawler()

        let pending = try await database.dbQueue.read { db in
            try Episode.filter(sql: "audioURL IS NULL").fetchAll(db)
        }
        let targets = limit > 0 ? Array(pending.prefix(limit)) : pending
        print("Resolving audio URLs for \(targets.count) episodes...")

        var resolved = 0
        for ep in targets {
            do {
                if let url = try await crawler.resolveAudioURL(itemId: ep.id) {
                    var updated = ep
                    updated.audioURL = url
                    let toSave = updated
                    try await database.dbQueue.write { db in try toSave.save(db) }
                    resolved += 1
                    if resolved % 25 == 0 { print("  resolved \(resolved)/\(targets.count)") }
                } else {
                    print("  no data-url found for episode \(ep.id) (\(ep.title))")
                }
            } catch {
                print("  failed for episode \(ep.id): \(error)")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        print("Done. Resolved \(resolved)/\(targets.count).")
    }
}

struct TranscribeBatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe-batch",
        abstract: "Resolve, download, transcribe, and store transcripts for pending episodes, one at a time."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var model: String = "models/ggml-small.en.bin"
    @Option(name: .long) var prompt: String = defaultPrompt
    @Option(name: .long) var limit: Int = 0 // 0 = no limit
    @Option(name: .long) var audioDir: String = "cache/audio"
    @Option(name: .long) var wavDir: String = "cache/wav"
    @Flag(name: .long) var keepAudio: Bool = false

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let crawler = LibsynCrawler()
        let transcriber = WhisperTranscriber(modelPath: model, initialPrompt: prompt)
        let downloader = AudioDownloader()

        try FileManager.default.createDirectory(atPath: audioDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: wavDir, withIntermediateDirectories: true)

        let pending = try await database.dbQueue.read { db in
            try Episode
                .filter(sql: "transcriptStatus = 'pending'")
                .order(sql: "episodeNumber IS NULL, episodeNumber ASC")
                .fetchAll(db)
        }
        let targets = limit > 0 ? Array(pending.prefix(limit)) : pending
        print("Transcribing \(targets.count) episodes (model: \(model))...")

        let startTime = Date()
        var done = 0
        var failed = 0

        for ep in targets {
            let label = "#\(ep.episodeNumber.map(String.init) ?? "?") (\(ep.id)) \(ep.title)"
            let wavPath = "\(wavDir)/\(ep.id).wav"
            let jsonBase = "\(wavDir)/\(ep.id)"
            var audioPath: String?

            do {
                guard let urlString = try await crawler.resolveAudioURL(itemId: ep.id),
                      let url = URL(string: urlString) else {
                    throw AudioDownloaderError.badStatus(-1)
                }
                // ffmpeg's demuxer probing leans on the file extension for ambiguous
                // containers -- a real .mp3 saved with a hardcoded .m4a name fails with
                // "moov atom not found" because it looks for an mp4 container that isn't
                // there. Always match the extension the source URL actually uses.
                let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
                let resolvedAudioPath = "\(audioDir)/\(ep.id).\(ext)"
                audioPath = resolvedAudioPath
                try await downloader.download(url: url, to: resolvedAudioPath)
                try transcriber.convertToWav(inputPath: resolvedAudioPath, outputPath: wavPath)
                let result = try transcriber.transcribe(wavPath: wavPath, outputBasePath: jsonBase)

                var updated = ep
                updated.transcriptText = result.fullText
                updated.transcriptStatus = "transcribed"
                updated.audioURL = urlString
                let segments = result.segments.map {
                    TranscriptSegment(episodeId: ep.id, startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
                }
                let toSave = updated
                try await database.dbQueue.write { db in
                    try toSave.save(db)
                    try db.execute(sql: "DELETE FROM transcript_segments WHERE episodeId = ?", arguments: [ep.id])
                    for seg in segments { try seg.insert(db) }
                }

                if !keepAudio {
                    try? FileManager.default.removeItem(atPath: resolvedAudioPath)
                    try? FileManager.default.removeItem(atPath: wavPath)
                }

                done += 1
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = elapsed / Double(done)
                let remaining = rate * Double(targets.count - done)
                print("[\(done)/\(targets.count)] done \(label) -- \(Int(result.segments.count)) segments, ~\(Int(remaining/60))min remaining")
            } catch {
                failed += 1
                var updated = ep
                updated.transcriptStatus = "failed"
                let toSave = updated
                try? await database.dbQueue.write { db in try toSave.save(db) }
                if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
                try? FileManager.default.removeItem(atPath: wavPath)
                print("[FAILED] \(label): \(error)")
            }
        }

        print("Batch complete. \(done) transcribed, \(failed) failed.")
    }
}

private struct CollectionDefinition: Codable {
    let slug: String
    let title: String
    let description: String
    let kind: String
}

struct Classify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "classify",
        abstract: "Classify transcribed episodes into curated collections via the Claude API."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var collectionsFile: String = "collections.json"
    @Option(name: .long) var limit: Int = 0 // 0 = no limit
    // Backfill mode: first cheaply re-resolves any unresolved item that already has a stored
    // quote (no LLM call, see the pass at the top of run()), then, for whatever episodes
    // still have unresolved items after that, falls back to the original heavier
    // path -- re-classifying the whole episode and clearing its existing collection_items
    // first. That fallback is a known, accepted tradeoff for legacy rows that predate the
    // `quote` column: it also regenerates already-resolved items via a fresh, non-deterministic
    // LLM call, so a previously-good match can be lost if the new call doesn't reproduce it.
    // Meant to be run once after a matching-logic improvement, to recover moments that fell
    // back to 0:00 under the old resolver without re-paying to reclassify episodes that
    // already matched fine.
    @Flag(name: .long) var onlyUnresolved: Bool = false

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let classifier = try ClaudeClassifier()

        let defsData = try Data(contentsOf: URL(fileURLWithPath: collectionsFile))
        let defs = try JSONDecoder().decode([CollectionDefinition].self, from: defsData)

        // Upsert by slug -- editing collections.json and re-running updates
        // titles/descriptions in place rather than duplicating rows.
        let collections = try await database.dbQueue.write { db -> [EpisodeCollection] in
            var result: [EpisodeCollection] = []
            for def in defs {
                if var existing = try EpisodeCollection.fetchOne(db, sql: "SELECT * FROM collections WHERE slug = ?", arguments: [def.slug]) {
                    existing.title = def.title
                    existing.collectionDescription = def.description
                    existing.kind = def.kind
                    try existing.save(db)
                    result.append(existing)
                } else {
                    var new = EpisodeCollection(slug: def.slug, title: def.title, collectionDescription: def.description, kind: def.kind)
                    try new.insert(db)
                    result.append(new)
                }
            }
            return result
        }
        let collectionBySlug = Dictionary(uniqueKeysWithValues: collections.map { ($0.slug, $0) })

        if onlyUnresolved {
            // Cheap, LLM-free pass: any unresolved row that already carries its original
            // quote (persisted since the `quote` column was added) can be retried directly
            // against the current resolveSegment logic and updated in place -- no delete, no
            // re-classify, so it can never regress an already-good sibling row. Only rows
            // that still come up empty after this fall through to the existing delete +
            // re-classify path below (the known, documented tradeoff for legacy rows that
            // predate the `quote` column).
            let quotedResolved = try await database.dbQueue.write { db -> Int in
                let candidates = try CollectionItem
                    .filter(sql: "segmentId IS NULL AND quote IS NOT NULL")
                    .fetchAll(db)
                var resolvedCount = 0
                for var item in candidates {
                    guard let quote = item.quote,
                          let segment = try resolveSegment(quote: quote, episodeId: item.episodeId, db: db)
                    else { continue }
                    item.segmentId = segment.id
                    item.timestampMs = segment.startMs
                    try item.save(db)
                    resolvedCount += 1
                }
                return resolvedCount
            }
            if quotedResolved > 0 {
                print("Resolved \(quotedResolved) previously-unresolved item(s) from stored quotes, no re-classify needed.")
            }
        }

        let pending = try await database.dbQueue.read { db in
            if onlyUnresolved {
                return try Episode
                    .filter(sql: """
                        transcriptText IS NOT NULL AND id IN (
                            SELECT DISTINCT episodeId FROM collection_items WHERE segmentId IS NULL
                        )
                        """)
                    .order(sql: "episodeNumber IS NULL, episodeNumber ASC")
                    .fetchAll(db)
            }
            return try Episode
                .filter(sql: "transcriptText IS NOT NULL AND classifiedAt IS NULL")
                .order(sql: "episodeNumber IS NULL, episodeNumber ASC")
                .fetchAll(db)
        }
        let targets = limit > 0 ? Array(pending.prefix(limit)) : pending
        print("Classifying \(targets.count) episodes against \(collections.count) collections...")

        var done = 0
        var matched = 0
        var failed = 0

        for ep in targets {
            let label = "#\(ep.episodeNumber.map(String.init) ?? "?") (\(ep.id)) \(ep.title)"
            guard let transcript = ep.transcriptText else { continue }
            do {
                let matches = try await classifier.classify(transcript: transcript, collections: collections)

                let insertedCount = try await database.dbQueue.write { db -> Int in
                    var insertedCount = 0
                    // Scoped to still-unresolved rows only -- NOT a wholesale delete of the
                    // whole episode. This episode reached the fallback re-classify path
                    // because it STILL has at least one unresolved item, but the cheap
                    // quote-based pass above may have already resolved OTHER items on this
                    // same episode in this very run; a blanket delete here would silently
                    // discard that just-completed work. Confirmed by code review: the
                    // previous version's unconditional `DELETE FROM collection_items WHERE
                    // episodeId = ?` did exactly that, undermining the cheap pass's own
                    // documented guarantee that it "can never regress an already-good
                    // sibling row" for any episode with a mix of resolved and unresolved
                    // items.
                    let keptItems: [CollectionItem] = onlyUnresolved ? try {
                        try db.execute(sql: "DELETE FROM collection_items WHERE episodeId = ? AND segmentId IS NULL", arguments: [ep.id])
                        return try CollectionItem.filter(sql: "episodeId = ?", arguments: [ep.id]).fetchAll(db)
                    }() : []
                    for match in matches {
                        guard let collection = collectionBySlug[match.collectionSlug], let collectionId = collection.id else {
                            print("  [\(label)] unknown collection slug '\(match.collectionSlug)', skipping")
                            continue
                        }
                        // Skip a fresh match that would duplicate an item just kept above --
                        // the LLM call returns the episode's FULL match set every time, not
                        // just what was missing, so without this a topic that's already
                        // correctly resolved (and deliberately not deleted, per the scoped
                        // DELETE above) would get a second, redundant row inserted alongside
                        // it. Matched by collection + exact blurb text; a differently-worded
                        // re-description of the same moment could still slip through as a
                        // near-duplicate, but that's a far smaller risk than the wholesale
                        // data loss this whole scoped-delete change exists to prevent.
                        if onlyUnresolved, keptItems.contains(where: { $0.collectionId == collectionId && $0.blurb == match.blurb }) {
                            continue
                        }
                        // Same corruption check `synthesize`/`generate-glossary` use -- a
                        // content-quality audit found a live blurb reading "The hosts read
                        // read a a listener email...". Rare (one match out of 4290 in the
                        // real corpus), but Museum's "Featured Moments" cards render this
                        // text directly, so it's worth skipping rather than storing.
                        guard !looksCorrupted(match.blurb) else {
                            print("  [\(label)] skipping corrupted blurb: \"\(match.blurb.prefix(80))\"")
                            continue
                        }
                        // Tiered lookup, loosest last -- the model is asked for a verbatim
                        // quote but doesn't reliably deliver one, so an exact match alone
                        // left ~35% of items with no resolved segment (silently falling
                        // back to 0:00 in the app). See resolveSegment's doc comment.
                        let segment = try resolveSegment(quote: match.quote, episodeId: ep.id, db: db)
                        let item = CollectionItem(
                            collectionId: collectionId,
                            episodeId: ep.id,
                            segmentId: segment?.id,
                            timestampMs: segment?.startMs,
                            blurb: match.blurb,
                            quote: match.quote
                        )
                        try item.insert(db)
                        insertedCount += 1
                    }
                    var updated = ep
                    updated.classifiedAt = ISO8601DateFormatter().string(from: Date())
                    try updated.save(db)
                    return insertedCount
                }

                done += 1
                // Actual rows inserted, not matches.count -- a corrupted or de-duplicated
                // match is skipped above without inserting, so counting the raw match array
                // overstated how many rows this episode actually added (confirmed by code
                // review after the corruption filter and dedup-on-skip were added above).
                matched += insertedCount
                print("[\(done)/\(targets.count)] \(label) -- \(insertedCount) match(es)")
            } catch {
                failed += 1
                print("[FAILED] \(label): \(error)")
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms politeness delay
        }

        print("Classification complete. \(done) episodes processed, \(matched) matches recorded, \(failed) failed.")
    }
}

/// Resolves which transcript segment a classifier-reported quote actually came from, so a
/// Museum moment card can jump to the right timestamp instead of falling back to 0:00.
/// Claude is asked for a short verbatim substring but doesn't reliably deliver one -- ASR
/// punctuation/casing quirks, or outright light paraphrasing -- so this tries progressively
/// looser tiers before giving up:
///   1. Exact substring match (fast path, handles the common case where the quote really is
///      verbatim -- same lookup this used to do unconditionally).
///   2. Punctuation/case/whitespace-normalized substring match across the whole episode's
///      transcript, so a quote that only differs by formatting (or straddles a segment
///      boundary) still resolves. The match's character offset in the concatenated,
///      normalized transcript is mapped back to whichever segment it falls inside.
///   3. Fuzzy word-overlap match against individual segments, for light paraphrasing --
///      scores each segment by the fraction of the quote's distinctive (length > 2) words
///      it contains, and only accepts a segment at 60%+ overlap so a few common words
///      scattered across the episode can't produce a false match.
/// Returns nil (falls back to 0:00, same as before) only when none of the three finds
/// anything -- e.g. the model invented a quote that isn't actually in the transcript.
private func resolveSegment(quote: String, episodeId: Int, db: Database) throws -> TranscriptSegment? {
    // An empty (or whitespace-only) quote must never reach the LIKE below -- unescaped it
    // would degenerate to "%%", matching the first segment of the episode at random.
    guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    // LIKE treats a literal '%' or '_' in the quote itself as a wildcard, so a quote
    // containing either (ASR transcripts occasionally do, e.g. "50% chance") would match far
    // more loosely than intended. Escape both (and the escape character itself) and pair with
    // ESCAPE '\' below.
    let escapedQuote = quote
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
    if let exact = try TranscriptSegment.fetchOne(db, sql: """
        SELECT * FROM transcript_segments
        WHERE episodeId = ? AND text LIKE ? ESCAPE '\\' COLLATE NOCASE
        LIMIT 1
        """, arguments: [episodeId, "%\(escapedQuote)%"]) {
        return exact
    }

    let segments = try TranscriptSegment
        .filter(sql: "episodeId = ?", arguments: [episodeId])
        .order(sql: "startMs ASC")
        .fetchAll(db)
    guard !segments.isEmpty else { return nil }

    let normalizedQuote = normalizeForMatching(quote)
    guard !normalizedQuote.isEmpty else { return nil }

    // Tier 2.
    var combined = ""
    var offsets: [(segment: TranscriptSegment, start: Int)] = []
    for segment in segments {
        offsets.append((segment, combined.count))
        combined += normalizeForMatching(segment.text) + " "
    }
    if let range = combined.range(of: normalizedQuote) {
        let matchStart = combined.distance(from: combined.startIndex, to: range.lowerBound)
        var best = offsets[0].segment
        for entry in offsets {
            guard entry.start <= matchStart else { break }
            best = entry.segment
        }
        return best
    }

    // Tier 3.
    let quoteWords = Set(normalizedQuote.split(separator: " ").map(String.init).filter { $0.count > 2 })
    guard quoteWords.count >= 3 else { return nil }

    var bestSegment: TranscriptSegment?
    var bestScore = 0.0
    for segment in segments {
        let segmentWords = Set(normalizeForMatching(segment.text).split(separator: " ").map(String.init))
        let score = Double(quoteWords.intersection(segmentWords).count) / Double(quoteWords.count)
        if score > bestScore {
            bestScore = score
            bestSegment = segment
        }
    }
    return bestScore >= 0.6 ? bestSegment : nil
}

/// Lowercases and strips everything but letters/digits/whitespace, collapsing runs of
/// whitespace to single spaces -- puts a classifier-reported quote and the raw ASR
/// transcript text on equal footing so formatting differences (curly vs. straight quotes,
/// "don't" vs "dont", stray commas) don't defeat a substring match that's otherwise exact.
private func normalizeForMatching(_ s: String) -> String {
    var result = ""
    result.reserveCapacity(s.count)
    var lastWasSpace = true // suppresses a leading space and collapses repeats
    for scalar in s.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
            lastWasSpace = false
        } else if !lastWasSpace {
            result.append(" ")
            lastWasSpace = true
        }
    }
    if result.hasSuffix(" ") { result.removeLast() }
    return result
}

/// Catches a rare but real class of generation glitch found in the live corpus during a
/// content-quality audit: a strict-mode tool call whose string field, instead of clean prose,
/// contains the model's own leaked meta-narration or a malformed echo of the tool-call syntax
/// itself -- e.g. a stored "ON RETROMACCAST" paragraph that literally began "</antml>\n\nI
/// apologize for that error. Let me write the paragraph properly...(newline)antml:invoke
/// name=\"record_synthesis\"\n<parameter name=\"paragraph\">...", or a glossary definition
/// that was nothing but ">antml:parameter>parameter>ml:parameter name=". Neither is a
/// hallucinated *fact* (the existing placeholder-word filter's job) -- it's the model
/// narrating its own retry, or corrupting the tool-call wrapper itself, into a field that's
/// supposed to hold only the finished text. Also catches plain doubled-word slips ("read read
/// a a listener email"), a second, unrelated defect found in the same audit. Not exhaustive --
/// a purely well-formed-but-still-wrong paragraph wouldn't trip this -- but it's a cheap,
/// specific backstop for exactly the failure shapes actually observed, same spirit as the
/// glossary placeholder filter below.
private func looksCorrupted(_ text: String) -> Bool {
    let artifactMarkers = ["antml", "apologize", "i need to", "let me write", "invoke name=", "parameter name="]
    let lower = text.lowercased()
    if artifactMarkers.contains(where: { lower.contains($0) }) { return true }
    if text.contains("</") || text.contains("<parameter") { return true }

    // Reuses `lower` (already computed above) rather than lowercasing the same text a
    // second time.
    let words = lower
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
    for i in 0..<max(words.count - 1, 0) {
        if words[i] == words[i + 1], words[i].count > 1 { return true }
    }
    return false
}

struct ResetStaleSynthesis: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset-stale-synthesis",
        abstract: "Clear the synthesized paragraph for any collection that gained an item from an episode classified since a given timestamp, so the next `synthesize` run regenerates just that paragraph instead of skipping it as already-done."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var since: String // ISO8601 timestamp, e.g. captured right before `classify` ran

    func run() async throws {
        let database = try RMCDatabase(path: db)

        let cleared = try await database.dbQueue.write { db -> Int in
            let staleCollectionIds = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT ci.collectionId
                FROM collection_items ci
                JOIN episodes e ON e.id = ci.episodeId
                WHERE e.classifiedAt >= ?
                """, arguments: [since])

            guard !staleCollectionIds.isEmpty else { return 0 }

            let placeholders = staleCollectionIds.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "UPDATE collections SET synthesizedParagraph = NULL WHERE id IN (\(placeholders))",
                arguments: StatementArguments(staleCollectionIds)
            )
            return staleCollectionIds.count
        }

        print("Cleared synthesis for \(cleared) collection(s) touched by episodes classified since \(since).")
    }
}

struct Synthesize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "synthesize",
        abstract: "Generate a per-collection \"ON RETROMACCAST\" summary paragraph from recorded collection items."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var limit: Int = 0 // 0 = no limit

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let classifier = try ClaudeClassifier()

        let collections = try await database.dbQueue.read { db in
            try EpisodeCollection.fetchAll(db)
        }
        let targets = limit > 0 ? Array(collections.prefix(limit)) : collections
        print("Synthesizing \(targets.count) collections...")

        var done = 0
        var skipped = 0
        var failed = 0

        for collection in targets {
            guard let collectionId = collection.id else { continue }
            guard collection.synthesizedParagraph == nil else {
                print("[\(done + skipped)/\(targets.count)] \(collection.title) -- already synthesized, skipping")
                continue
            }
            let moments = try await database.dbQueue.read { db -> [(String, String)] in
                let items = try CollectionItem.filter(sql: "collectionId = ?", arguments: [collectionId]).fetchAll(db)
                return try items.compactMap { item -> (String, String)? in
                    guard let episode = try Episode.fetchOne(db, sql: "SELECT * FROM episodes WHERE id = ?", arguments: [item.episodeId]) else { return nil }
                    return (episode.title, item.blurb)
                }
            }

            guard !moments.isEmpty else {
                skipped += 1
                print("[\(done + skipped)/\(targets.count)] \(collection.title) -- no matched episodes, skipping")
                continue
            }

            do {
                let synthesizeArgs = moments.map { (episodeTitle: $0.0, blurb: $0.1) }
                var paragraph = try await classifier.synthesize(productTitle: collection.title, moments: synthesizeArgs)
                // Up to 2 retries (3 attempts total), not just 1 -- confirmed live that this
                // class of glitch, while rare across the corpus overall, can be stubbornly
                // reproducible for a specific product's own moment list (one real product
                // came back corrupted on 4 consecutive attempts across two separate runs
                // before finally succeeding on a later one), so a single retry isn't always
                // enough headroom.
                var attempt = 1
                var isCorrupted = looksCorrupted(paragraph)
                while isCorrupted, attempt < 3 {
                    attempt += 1
                    print("  [\(collection.title)] attempt \(attempt - 1) looked corrupted, retrying (attempt \(attempt)/3)...")
                    paragraph = try await classifier.synthesize(productTitle: collection.title, moments: synthesizeArgs)
                    // Tracked alongside `paragraph`, not re-derived after the loop -- the
                    // loop's own last iteration already computed this; re-running the same
                    // multi-step string scan again immediately afterward on an unchanged
                    // value was pure redundant work.
                    isCorrupted = looksCorrupted(paragraph)
                }
                guard !isCorrupted else {
                    throw ClaudeClassifierError.corruptedGeneration(collection.title)
                }
                let finalParagraph = paragraph
                try await database.dbQueue.write { db in
                    var updated = collection
                    updated.synthesizedParagraph = finalParagraph
                    try updated.save(db)
                }
                done += 1
                print("[\(done + skipped)/\(targets.count)] \(collection.title) -- synthesized from \(moments.count) moment(s)")
            } catch {
                failed += 1
                print("[FAILED] \(collection.title): \(error)")
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms politeness delay
        }

        print("Synthesis complete. \(done) synthesized, \(skipped) skipped (no episodes), \(failed) failed.")
    }
}

struct GenerateTrivia: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-trivia",
        abstract: "Mine collection_items blurbs for standalone trivia facts about the show, in batches, via the Claude API."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var batchSize: Int = 50
    /// Only consider episodes classified since this ISO8601 timestamp -- for a cheap
    /// incremental top-up after the initial full-corpus bootstrap run. Omit for the bootstrap.
    @Option(name: .long) var since: String?
    /// Caps how many batches actually run, for a cheap test call before committing to the
    /// full (paid) pass. 0 = no limit.
    @Option(name: .long) var limitBatches: Int = 0

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let classifier = try ClaudeClassifier()

        // Only collection_items with a resolved segmentId -- these are the only ones with a
        // real timestamp, so they're the only ones a trivia fact can actually jump playback to.
        // Feeding the model blurbs with no anchor produced facts that looked identical in the
        // UI but silently fell back to playing the episode from 0:00 instead of the moment,
        // which defeats the point of the play button being there at all.
        let episodes = try await database.dbQueue.read { db -> [Episode] in
            var sql = """
                SELECT DISTINCT episodes.* FROM episodes
                JOIN collection_items ON collection_items.episodeId = episodes.id
                WHERE collection_items.segmentId IS NOT NULL
                """
            var arguments: [DatabaseValueConvertible] = []
            if let since {
                sql += " AND episodes.classifiedAt >= ?"
                arguments.append(since)
            }
            sql += " ORDER BY episodes.episodeNumber IS NULL, episodes.episodeNumber ASC"
            return try Episode.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }

        guard !episodes.isEmpty else {
            print("No episodes with collection items found\(since != nil ? " since \(since!)" : "") -- nothing to do.")
            return
        }

        let batches = stride(from: 0, to: episodes.count, by: batchSize).map {
            Array(episodes[$0..<min($0 + batchSize, episodes.count)])
        }
        let targets = limitBatches > 0 ? Array(batches.prefix(limitBatches)) : batches
        print("Generating trivia from \(episodes.count) episodes across \(targets.count) batch(es) (of \(batches.count) total)...")

        var totalFacts = 0
        var unresolved = 0

        for (index, batch) in targets.enumerated() {
            let episodeBlurbs = try await database.dbQueue.read { db in
                try batch.map { ep -> (title: String, pubDate: String, blurbs: [String]) in
                    let blurbs = try String.fetchAll(db, sql: "SELECT blurb FROM collection_items WHERE episodeId = ? AND segmentId IS NOT NULL", arguments: [ep.id])
                    return (title: ep.title, pubDate: ep.pubDate, blurbs: blurbs)
                }
            }

            do {
                let facts = try await classifier.generateTrivia(episodes: episodeBlurbs)

                // Scopes the sourceBlurb lookup below to just this batch's own episodes --
                // `generateTrivia` only ever sees blurbs from THIS batch in its single prompt,
                // so a duplicate blurb text belonging to some other, unrelated episode
                // elsewhere in the whole corpus was never a candidate the model could
                // actually have meant, and shouldn't be a candidate for the lookup either.
                let batchEpisodeIds = batch.compactMap { $0.id }
                let batchUnresolved = try await database.dbQueue.write { db -> Int in
                    var batchUnresolved = 0
                    for fact in facts {
                        // Resolve the verbatim sourceBlurb back to the exact collection_item it
                        // came from -- this is the only source of episodeId/segmentId/timestampMs,
                        // deliberately not trusted from the model directly (see ClaudeClassifier
                        // .generateTrivia's doc comment). A nil sourceBlurb (aggregate fact) or one
                        // that fails to match verbatim both fall through to an unlinked fact rather
                        // than a guessed episode.
                        var sourceItem: CollectionItem?
                        if let rawSourceBlurb = fact.sourceBlurb {
                            // Defensive trim -- the model occasionally echoes a little
                            // surrounding whitespace even when told not to; a stray leading
                            // space shouldn't be the difference between a linked and unlinked
                            // fact when the actual content matched.
                            let sourceBlurb = rawSourceBlurb.trimmingCharacters(in: .whitespacesAndNewlines)
                            // Scoped to this batch's own episodes (see batchEpisodeIds' doc
                            // comment above) with a deterministic ORDER BY id as a final
                            // tiebreaker -- the old unscoped, unordered `LIMIT 1` could
                            // silently attribute a fact to whichever row of a duplicate blurb
                            // SQLite happened to return first, anywhere in the whole corpus.
                            let idList = batchEpisodeIds.map(String.init).joined(separator: ",")
                            sourceItem = try CollectionItem.fetchOne(db, sql: """
                                SELECT * FROM collection_items
                                WHERE blurb = ? AND episodeId IN (\(idList))
                                ORDER BY id ASC LIMIT 1
                                """, arguments: [sourceBlurb])
                            if sourceItem == nil {
                                batchUnresolved += 1
                                print("  [batch \(index + 1)] sourceBlurb didn't match verbatim, storing unlinked: \"\(sourceBlurb.prefix(60))...\"")
                            }
                        }
                        var triviaFact = TriviaFact(
                            factText: fact.factText,
                            episodeId: sourceItem?.episodeId,
                            segmentId: sourceItem?.segmentId,
                            timestampMs: sourceItem?.timestampMs,
                            createdAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try triviaFact.insert(db)
                    }
                    return batchUnresolved
                }
                unresolved += batchUnresolved
                totalFacts += facts.count
                print("[batch \(index + 1)/\(targets.count)] +\(facts.count) facts (\(batch.count) episodes)")
            } catch {
                print("[FAILED] batch \(index + 1): \(error)")
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms politeness delay
        }

        print("Trivia generation complete. \(totalFacts) facts recorded (\(unresolved) unlinked from a failed sourceBlurb match).")
    }
}

struct GenerateGlossary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-glossary",
        abstract: "Mine each episode's full transcript for vintage Mac/Apple terminology the hosts actually explain, via the Claude API."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var limit: Int = 0 // 0 = no limit -- caps how many episodes run, for a cheap test pass before committing to the full corpus
    // Wipes every existing glossary_terms row and glossaryMinedAt marker before mining, so a
    // full run doesn't mix data mined under an older, since-corrected prompt (e.g. before
    // Museum-product-name exclusion was added) in with the new run's output. Not meant for
    // routine incremental runs -- only after a real prompt change invalidates prior results.
    @Flag(name: .long) var reset: Bool = false

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let classifier = try ClaudeClassifier()

        if reset {
            try await database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM glossary_terms")
                try db.execute(sql: "UPDATE episodes SET glossaryMinedAt = NULL")
            }
            print("Reset: cleared all glossary_terms and glossaryMinedAt.")
        }

        let pending = try await database.dbQueue.read { db in
            try Episode
                .filter(sql: "transcriptText IS NOT NULL AND glossaryMinedAt IS NULL")
                .order(sql: "episodeNumber IS NULL, episodeNumber ASC")
                .fetchAll(db)
        }
        let targets = limit > 0 ? Array(pending.prefix(limit)) : pending
        print("Mining glossary terms from \(targets.count) episode(s)...")

        var done = 0
        var totalTerms = 0
        var resolved = 0
        var failed = 0

        for ep in targets {
            let label = "#\(ep.episodeNumber.map(String.init) ?? "?") (\(ep.id)) \(ep.title)"
            guard let transcript = ep.transcriptText else { continue }
            let callStart = ContinuousClock.now
            do {
                let rawMatches = try await classifier.generateGlossaryTerms(transcript: transcript)
                // Defensive backstop, not the primary fix (that's the prompt's now-explicit
                // "return [] rather than inventing a filler entry" instruction) -- confirmed
                // live that even with that instruction, a strict-mode tool call can still
                // occasionally hallucinate a single junk entry (literally "term": "placeholder")
                // for an episode with nothing real to report, rather than truly returning an
                // empty array. Filters anything that looks like that pattern before it ever
                // reaches the database.
                let matches = rawMatches.filter { match in
                    let placeholderWords: Set<String> = ["placeholder", "x", "n/a", "none", "example"]
                    let term = match.term.trimmingCharacters(in: .whitespacesAndNewlines)
                    let definition = match.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !term.isEmpty, !definition.isEmpty, definition.count >= 15 else { return false }
                    guard !placeholderWords.contains(term.lowercased()) else { return false }
                    // Same corruption check `synthesize` retries on -- a content-quality
                    // audit found a live glossary definition that was nothing but
                    // ">antml:parameter>parameter>ml:parameter name=" (a malformed tool-call
                    // echo) and another badly word-corrupted one. No retry here (this filters
                    // a whole batch of matches per episode, not one isolated string), just
                    // drop the bad entry -- losing one term from an episode that likely
                    // yielded several others is a fine trade against storing garbage.
                    return !looksCorrupted(term) && !looksCorrupted(definition)
                }
                let skipped = rawMatches.count - matches.count
                if skipped > 0 {
                    // Prints the actual filtered term/definition, not just a count -- a bare
                    // count alone left no way to tell, after the fact, whether the filter is
                    // correctly catching real junk or overreaching on borderline-but-legitimate
                    // entries (exactly the ambiguity that came up diagnosing this filter's own
                    // trigger rate this session).
                    let filteredOut = rawMatches.filter { m in !matches.contains { $0.term == m.term && $0.quote == m.quote } }
                    for m in filteredOut {
                        print("  [\(label)] filtered: term=\"\(m.term)\" definition=\"\(m.definition.prefix(80))\"")
                    }
                }

                let episodeResolved = try await database.dbQueue.write { db -> Int in
                    var episodeResolved = 0
                    for match in matches {
                        // Same tiered lookup `classify` uses (see resolveSegment's doc
                        // comment) -- a term with no resolved segment still gets its
                        // definition recorded (better than losing real content mined at real
                        // API cost), it just won't have a jump-to-moment link in the app;
                        // never falls back to a fake `0`, matching this session's fix to the
                        // same anti-pattern in `classify`.
                        let segment = try resolveSegment(quote: match.quote, episodeId: ep.id, db: db)
                        if segment != nil { episodeResolved += 1 }
                        var term = GlossaryTerm(
                            term: match.term,
                            expansion: match.expansion,
                            definition: match.definition,
                            episodeId: ep.id,
                            segmentId: segment?.id,
                            timestampMs: segment?.startMs,
                            createdAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try term.insert(db)
                    }
                    var updated = ep
                    updated.glossaryMinedAt = ISO8601DateFormatter().string(from: Date())
                    try updated.save(db)
                    return episodeResolved
                }

                resolved += episodeResolved
                done += 1
                totalTerms += matches.count
                print("[\(done)/\(targets.count)] \(label) -- \(matches.count) term(s)")
            } catch {
                failed += 1
                print("[FAILED] \(label): \(error)")
            }
            // Only tops up to a 200ms floor between API calls -- the mining call itself
            // almost always already takes longer than that, so sleeping the full 200ms
            // unconditionally on top was pure added idle time (~2.4 min across a 718-episode
            // run) rather than real rate-limiting.
            let elapsed = callStart.duration(to: .now)
            if elapsed < .milliseconds(200) {
                try await Task.sleep(for: .milliseconds(200) - elapsed)
            }
        }

        print("Glossary mining complete. \(done) episodes processed, \(totalTerms) terms recorded (\(resolved) with a resolved moment), \(failed) failed.")
    }
}

struct SyncVideos: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-videos",
        abstract: "Fetch the show's YouTube channel uploads via the YouTube Data API and upsert them into the corpus DB."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var channelHandle: String = "@RetroMacCast"
    /// Caps how many videos are actually processed (bounds YouTubeClient's pagination too,
    /// not just the result), for a cheap test call. 0 = no limit.
    @Option(name: .long) var limit: Int = 0

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let client = try YouTubeClient()

        let uploadsPlaylistId = try await client.fetchUploadsPlaylistId(handle: channelHandle)
        let items = try await client.fetchAllPlaylistItems(playlistId: uploadsPlaylistId, limit: limit)
        print("Fetched \(items.count) videos from \(channelHandle)'s uploads playlist.")

        let durations = try await client.fetchDurations(videoIds: items.map(\.videoId))

        // episodeNumber -> episode id, loaded once rather than a query per video.
        let episodesByNumber = try await database.dbQueue.read { db -> [Int: Int] in
            let episodes = try Episode.fetchAll(db, sql: "SELECT * FROM episodes WHERE episodeNumber IS NOT NULL")
            var map: [Int: Int] = [:]
            for episode in episodes {
                if let number = episode.episodeNumber { map[number] = episode.id }
            }
            return map
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let matched = try await database.dbQueue.write { db -> Int in
            var matched = 0
            for item in items {
                let episodeNumber = YouTubeClient.extractEpisodeNumber(fromTitle: item.title)
                let episodeId = episodeNumber.flatMap { episodesByNumber[$0] }
                if episodeId != nil { matched += 1 }
                let video = Video(
                    id: item.videoId,
                    title: item.title,
                    publishedAt: item.publishedAt,
                    thumbnailURL: item.thumbnailURL,
                    durationSeconds: durations[item.videoId],
                    episodeId: episodeId,
                    syncedAt: now
                )
                // save() is update-else-insert against the primary key (the video id
                // itself) -- re-running this command upserts in place, never duplicates.
                try video.save(db)
            }
            return matched
        }

        print("Synced \(items.count) videos (\(matched) matched to an episode, \(items.count - matched) unlinked).")
    }
}

struct ExportManifest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-manifest",
        abstract: "Write a small JSON summary of the corpus (episode count, latest episode) alongside the database, so a client can sanity-check what it downloaded without opening the DB."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var output: String = "corpus/manifest.json"

    private struct Manifest: Codable {
        let episodeCount: Int
        let videoCount: Int
        let latestEpisodeId: Int?
        let latestEpisodeTitle: String?
        let latestEpisodePubDate: String?
        let generatedAt: String
    }

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let (count, latest, videoCount) = try await database.dbQueue.read { db -> (Int, Episode?, Int) in
            let count = try Episode.fetchCount(db)
            let latest = try Episode.order(sql: "pubDate DESC").fetchOne(db)
            let videoCount = try Video.fetchCount(db)
            return (count, latest, videoCount)
        }

        let manifest = Manifest(
            episodeCount: count,
            videoCount: videoCount,
            latestEpisodeId: latest?.id,
            latestEpisodeTitle: latest?.title,
            latestEpisodePubDate: latest?.pubDate,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: URL(fileURLWithPath: output))
        print("Wrote manifest to \(output): \(count) episodes, latest: \(latest?.title ?? "none")")
    }
}

struct Stats: AsyncParsableCommand {
    @Option(name: .long) var db: String = defaultDBPath

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let (total, withAudio, transcribed) = try await database.dbQueue.read { db in
            let total = try Episode.fetchCount(db)
            let withAudio = try Episode.filter(sql: "audioURL IS NOT NULL").fetchCount(db)
            let transcribed = try Episode.filter(sql: "transcriptStatus = 'transcribed'").fetchCount(db)
            return (total, withAudio, transcribed)
        }
        print("Episodes indexed: \(total)")
        print("Audio URLs resolved: \(withAudio)")
        print("Transcribed: \(transcribed)")
    }
}
