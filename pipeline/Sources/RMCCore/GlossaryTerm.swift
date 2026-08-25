import GRDB

/// A single dictionary-style definition of a piece of vintage Mac/Apple jargon, mined from the
/// archive by `generate-glossary` -- one row per (term, episode) mention, since the same term
/// (e.g. "SCSI") can legitimately come up and get explained in several different episodes.
/// `episodeId`/`segmentId`/`timestampMs` are non-optional together (unlike `TriviaFact`'s
/// aggregate-fact case) -- a glossary entry only exists because it was spotted being explained
/// at one specific moment, so there's no standalone-fact variant here.
public struct GlossaryTerm: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "glossary_terms"

    public var id: Int64?
    public var term: String
    /// The spelled-out acronym, e.g. "Apple Desktop Bus" for "ADB" -- nil when `term` already
    /// is the full name (e.g. "HyperCard").
    public var expansion: String?
    public var definition: String
    public var episodeId: Int
    public var segmentId: Int64?
    public var timestampMs: Int?
    public var createdAt: String

    public init(
        id: Int64? = nil,
        term: String,
        expansion: String? = nil,
        definition: String,
        episodeId: Int,
        segmentId: Int64? = nil,
        timestampMs: Int? = nil,
        createdAt: String
    ) {
        self.id = id
        self.term = term
        self.expansion = expansion
        self.definition = definition
        self.episodeId = episodeId
        self.segmentId = segmentId
        self.timestampMs = timestampMs
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
