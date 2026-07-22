import GRDB

public struct TranscriptSegment: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcript_segments"

    public var id: Int64?
    public var episodeId: Int
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(id: Int64? = nil, episodeId: Int, startMs: Int, endMs: Int, text: String) {
        self.id = id
        self.episodeId = episodeId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
