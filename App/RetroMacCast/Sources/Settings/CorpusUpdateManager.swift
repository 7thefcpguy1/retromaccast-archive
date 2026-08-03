import Foundation
import GRDB

/// Checks the GitHub repo's Releases for a newer corpus (published weekly by the
/// `weekly-sync.yml` Actions workflow, incrementally re-transcribed/classified/synthesized --
/// never a full rebuild), downloads it, validates it, and swaps it into `Corpus.shared`.
///
/// Auto-check is "weekly by default" without any real background-refresh scheduling: `checkIfDue()`
/// is called once per launch from the root view and only actually hits the network if it's been
/// 7+ days (or never) since the last check. `checkForUpdate()` is the same call a manual
/// "Check Now" button in Settings triggers directly, bypassing the 7-day gate.
@MainActor
final class CorpusUpdateManager: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastCheckedDate: Date?
    @Published private(set) var currentEpisodeCount: Int?
    @Published private(set) var currentLatestEpisodeTitle: String?

    private static let owner = "7thefcpguy1"
    private static let repo = "retromaccast-archive"

    private static let lastKnownTagKey = "CorpusUpdateManager.lastKnownReleaseTag"
    private static let lastCheckedDateKey = "CorpusUpdateManager.lastCheckedDate"
    private static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    init() {
        lastCheckedDate = UserDefaults.standard.object(forKey: Self.lastCheckedDateKey) as? Date
        refreshCurrentStats()
    }

    /// Called once per launch. Only actually checks the network if a week (or more) has
    /// passed since the last check -- this is what makes the default cadence "weekly"
    /// without needing a real background task scheduler, which nothing else in this app uses.
    func checkIfDue() async {
        let dueDate = lastCheckedDate.map { $0.addingTimeInterval(Self.checkInterval) } ?? .distantPast
        guard Date() >= dueDate else { return }
        await checkForUpdate()
    }

    /// The same check a manual "Check Now" button calls directly -- ignores the weekly gate.
    func checkForUpdate() async {
        guard !isChecking, !isDownloading else { return }
        isChecking = true
        defer { isChecking = false }

        lastCheckedDate = Date()
        UserDefaults.standard.set(lastCheckedDate, forKey: Self.lastCheckedDateKey)

        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                statusMessage = "Couldn't check for updates right now."
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            let lastKnownTag = UserDefaults.standard.string(forKey: Self.lastKnownTagKey)
            guard release.tagName != lastKnownTag else {
                statusMessage = "Up to date."
                return
            }

            guard let dbAsset = release.assets.first(where: { $0.name == "rmc.sqlite" }) else {
                statusMessage = "Latest release is missing its database file."
                return
            }

            statusMessage = "Downloading update..."
            try await downloadAndApply(assetURL: dbAsset.browserDownloadURL, tag: release.tagName)
        } catch {
            statusMessage = "Couldn't check for updates: \(error.localizedDescription)"
        }
    }

    private func downloadAndApply(assetURL: URL, tag: String) async throws {
        isDownloading = true
        defer { isDownloading = false }

        let (tempURL, _) = try await URLSession.shared.download(from: assetURL)

        // Sanity-check the download before committing to it -- open read-only and run a
        // trivial query, so a truncated or corrupt download can't take down the app on its
        // next launch.
        var config = Configuration()
        config.readonly = true
        let testQueue = try DatabaseQueue(path: tempURL.path, configuration: config)
        let episodeCount = try await testQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM episodes") ?? 0
        }
        guard episodeCount > 0 else {
            statusMessage = "The downloaded file looked invalid -- kept the current database."
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let destination = Corpus.downloadedDBURL
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        Corpus.reloadFromDisk()
        UserDefaults.standard.set(tag, forKey: Self.lastKnownTagKey)
        refreshCurrentStats()
        statusMessage = "Updated to \(episodeCount.formatted(.number.grouping(.automatic))) episodes."
    }

    private func refreshCurrentStats() {
        currentEpisodeCount = try? Corpus.shared.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM episodes") ?? 0
        }
        currentLatestEpisodeTitle = try? Corpus.shared.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM episodes ORDER BY pubDate DESC LIMIT 1")
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}
