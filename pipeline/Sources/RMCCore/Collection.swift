import GRDB

// Named EpisodeCollection, not Collection -- a bare "Collection" struct would shadow
// Swift's stdlib Collection protocol (which Array, String, etc. all conform to) and
// risks ambiguity anywhere this module writes a generic constraint against it.
public struct EpisodeCollection: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "collections"

    public var id: Int64?
    public var slug: String
    public var title: String
    public var collectionDescription: String
    public var kind: String // "product_timeline" | "recurring_segment"
    /// A synthesized paragraph summarizing how the show has discussed this collection across
    /// its history -- nil until the `synthesize` pipeline pass has run (or if it found nothing
    /// to synthesize from, i.e. zero matched episodes).
    public var synthesizedParagraph: String?

    public init(
        id: Int64? = nil,
        slug: String,
        title: String,
        collectionDescription: String,
        kind: String,
        synthesizedParagraph: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.collectionDescription = collectionDescription
        self.kind = kind
        self.synthesizedParagraph = synthesizedParagraph
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
