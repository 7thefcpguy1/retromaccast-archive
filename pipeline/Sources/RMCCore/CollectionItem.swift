import GRDB

public struct CollectionItem: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collection_items"

    public var id: Int64?
    public var collectionId: Int64
    public var episodeId: Int
    public var segmentId: Int64?
    public var timestampMs: Int?
    public var blurb: String

    public init(
        id: Int64? = nil,
        collectionId: Int64,
        episodeId: Int,
        segmentId: Int64? = nil,
        timestampMs: Int? = nil,
        blurb: String
    ) {
        self.id = id
        self.collectionId = collectionId
        self.episodeId = episodeId
        self.segmentId = segmentId
        self.timestampMs = timestampMs
        self.blurb = blurb
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
