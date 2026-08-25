import GRDB

public struct Episode: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "episodes"

    public var id: Int // Libsyn item id (data-id), stable primary key
    public var episodeNumber: Int?
    public var title: String
    public var pageURL: String
    public var pubDate: String // ISO 8601 date, e.g. "2006-12-18"
    public var showNotesHTML: String
    public var audioURL: String?
    public var audioLocalPath: String?
    public var transcriptStatus: String // pending | downloaded | transcribed | failed
    public var transcriptText: String?
    public var classifiedAt: String? // ISO date; nil = not yet run through collection classification
    public var glossaryMinedAt: String? // ISO date; nil = not yet run through generate-glossary

    public init(
        id: Int,
        episodeNumber: Int?,
        title: String,
        pageURL: String,
        pubDate: String,
        showNotesHTML: String,
        audioURL: String? = nil,
        audioLocalPath: String? = nil,
        transcriptStatus: String = "pending",
        transcriptText: String? = nil,
        classifiedAt: String? = nil,
        glossaryMinedAt: String? = nil
    ) {
        self.id = id
        self.episodeNumber = episodeNumber
        self.title = title
        self.pageURL = pageURL
        self.pubDate = pubDate
        self.showNotesHTML = showNotesHTML
        self.audioURL = audioURL
        self.audioLocalPath = audioLocalPath
        self.transcriptStatus = transcriptStatus
        self.transcriptText = transcriptText
        self.classifiedAt = classifiedAt
        self.glossaryMinedAt = glossaryMinedAt
    }
}
