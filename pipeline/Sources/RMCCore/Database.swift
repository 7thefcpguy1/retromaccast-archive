import Foundation
import GRDB

public struct RMCDatabase {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createEpisodes") { db in
            try db.create(table: "episodes") { t in
                t.column("id", .integer).primaryKey()
                t.column("episodeNumber", .integer)
                t.column("title", .text).notNull()
                t.column("pageURL", .text).notNull()
                t.column("pubDate", .text).notNull()
                t.column("showNotesHTML", .text).notNull()
                t.column("audioURL", .text)
                t.column("audioLocalPath", .text)
                t.column("transcriptStatus", .text).notNull().defaults(to: "pending")
                t.column("transcriptText", .text)
            }
        }

        migrator.registerMigration("createSegments") { db in
            try db.create(table: "transcript_segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("episodeId", .integer).notNull().indexed().references("episodes", onDelete: .cascade)
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("text", .text).notNull()
            }
        }

        migrator.registerMigration("createFTS") { db in
            try db.create(virtualTable: "episodes_fts", using: FTS5()) { t in
                t.synchronize(withTable: "episodes")
                t.column("title")
                t.column("showNotesHTML")
                t.column("transcriptText")
            }
        }

        return migrator
    }
}
