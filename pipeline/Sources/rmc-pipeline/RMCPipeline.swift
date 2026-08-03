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
            ResetStaleSynthesis.self, Synthesize.self, ExportManifest.self, Stats.self,
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

        while year < currentYear || (year == currentYear && month <= currentMonth) {
            let episodes = try await crawler.fetchMonthPage(year: year, month: month)
            monthsChecked += 1
            if !episodes.isEmpty {
                try await database.dbQueue.write { db in
                    for ep in episodes {
                        try ep.save(db)
                    }
                }
                totalFound += episodes.count
                print("\(year)-\(String(format: "%02d", month)): +\(episodes.count) episodes (total \(totalFound))")
            }

            month += 1
            if month > 12 {
                month = 1
                year += 1
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms politeness delay
        }

        print("Done. Checked \(monthsChecked) months, indexed \(totalFound) episodes into \(db).")
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

        let pending = try await database.dbQueue.read { db in
            try Episode
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

                try await database.dbQueue.write { db in
                    for match in matches {
                        guard let collection = collectionBySlug[match.collectionSlug], let collectionId = collection.id else {
                            print("  [\(label)] unknown collection slug '\(match.collectionSlug)', skipping")
                            continue
                        }
                        // Same LIKE-based segment lookup the app's search uses to find
                        // a snippet's timestamp -- if the model paraphrased instead of
                        // quoting verbatim, no segment is found and the item is stored
                        // with no timestamp (plays from 0:00), same fallback as a
                        // title-only search match.
                        let segment = try TranscriptSegment.fetchOne(db, sql: """
                            SELECT * FROM transcript_segments
                            WHERE episodeId = ? AND text LIKE ? COLLATE NOCASE
                            LIMIT 1
                            """, arguments: [ep.id, "%\(match.quote)%"])
                        let item = CollectionItem(
                            collectionId: collectionId,
                            episodeId: ep.id,
                            segmentId: segment?.id,
                            timestampMs: segment?.startMs,
                            blurb: match.blurb
                        )
                        try item.insert(db)
                    }
                    var updated = ep
                    updated.classifiedAt = ISO8601DateFormatter().string(from: Date())
                    try updated.save(db)
                }

                done += 1
                matched += matches.count
                print("[\(done)/\(targets.count)] \(label) -- \(matches.count) match(es)")
            } catch {
                failed += 1
                print("[FAILED] \(label): \(error)")
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms politeness delay
        }

        print("Classification complete. \(done) episodes processed, \(matched) matches recorded, \(failed) failed.")
    }
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
                let paragraph = try await classifier.synthesize(
                    productTitle: collection.title,
                    moments: moments.map { (episodeTitle: $0.0, blurb: $0.1) }
                )
                try await database.dbQueue.write { db in
                    var updated = collection
                    updated.synthesizedParagraph = paragraph
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

struct ExportManifest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-manifest",
        abstract: "Write a small JSON summary of the corpus (episode count, latest episode) alongside the database, so a client can sanity-check what it downloaded without opening the DB."
    )

    @Option(name: .long) var db: String = defaultDBPath
    @Option(name: .long) var output: String = "corpus/manifest.json"

    private struct Manifest: Codable {
        let episodeCount: Int
        let latestEpisodeId: Int?
        let latestEpisodeTitle: String?
        let latestEpisodePubDate: String?
        let generatedAt: String
    }

    func run() async throws {
        let database = try RMCDatabase(path: db)
        let (count, latest) = try await database.dbQueue.read { db -> (Int, Episode?) in
            let count = try Episode.fetchCount(db)
            let latest = try Episode.order(sql: "pubDate DESC").fetchOne(db)
            return (count, latest)
        }

        let manifest = Manifest(
            episodeCount: count,
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
