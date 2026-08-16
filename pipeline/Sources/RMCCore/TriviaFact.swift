import GRDB

/// A single fact about the show, generated from the archive by `generate-trivia`.
/// `episodeId`/`segmentId`/`timestampMs` are nullable together: a fact tied to one specific
/// moment ("hear it here") sets all three; a cross-episode aggregate fact ("James and John
/// have referenced HyperCard in over 40 episodes") leaves them nil and stands on its own.
/// Shape deliberately mirrors `CollectionItem` so the app's existing "play in context"
/// plumbing (built for `CollectionItemResult`) can be reused as-is.
public struct TriviaFact: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "trivia_facts"

    public var id: Int64?
    public var factText: String
    public var episodeId: Int?
    public var segmentId: Int64?
    public var timestampMs: Int?
    public var createdAt: String

    public init(
        id: Int64? = nil,
        factText: String,
        episodeId: Int? = nil,
        segmentId: Int64? = nil,
        timestampMs: Int? = nil,
        createdAt: String
    ) {
        self.id = id
        self.factText = factText
        self.episodeId = episodeId
        self.segmentId = segmentId
        self.timestampMs = timestampMs
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
