import ArgumentParser
import Foundation
import RMCCore

let defaultDBPath = "corpus/rmc.sqlite"

let defaultPrompt = "Macintosh, Apple, RetroMacCast, James, John, Steve Jobs, Steve Wozniak, Woz, iPhone, iPod, iMac, iBook, PowerBook, PowerMac, Quadra, Performa, LC, SE, Plus, Classic, G3, G4, G5, System 7, Mac OS, eBay, KansasFest, MacWorld Expo, Vintage Computer Federation, VCF, AppleTalk, LocalTalk, SCSI, ADB, HyperCard, floppy disk, 68k, PowerPC, folklore.org"

@main
struct RMCPipeline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmc-pipeline",
        subcommands: [CrawlIndex.self, ResolveAudio.self, TranscribeBatch.self, Stats.self]
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
