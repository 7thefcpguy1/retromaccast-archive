import GRDB

/// One YouTube upload from the show's channel, synced by `sync-videos`. `episodeId` is a
/// best-effort regex match against the video title (see YouTubeClient) -- nil for anything
/// that doesn't look like a numbered episode recording (bonus footage, vintage ephemera,
/// live streams), same nullable-optional shape as `TriviaFact.episodeId`.
///
/// `PersistableRecord`, not `MutablePersistableRecord` -- unlike `TriviaFact`/`CollectionItem`,
/// the id is known up front (it's the YouTube video id itself, not a SQLite autoincrement),
/// so there's no `didInsert` callback needed. That's also what makes re-running `sync-videos`
/// a plain upsert: `save(db)` updates-if-exists-else-inserts against the primary key.
public struct Video: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "videos"

    public var id: String // YouTube video id, e.g. "dQw4w9WgXcQ"
    public var title: String
    public var publishedAt: String // ISO8601
    public var thumbnailURL: String
    public var durationSeconds: Int?
    public var episodeId: Int?
    public var syncedAt: String // ISO8601, when this row was last upserted

    public init(
        id: String,
        title: String,
        publishedAt: String,
        thumbnailURL: String,
        durationSeconds: Int? = nil,
        episodeId: Int? = nil,
        syncedAt: String
    ) {
        self.id = id
        self.title = title
        self.publishedAt = publishedAt
        self.thumbnailURL = thumbnailURL
        self.durationSeconds = durationSeconds
        self.episodeId = episodeId
        self.syncedAt = syncedAt
    }
}
