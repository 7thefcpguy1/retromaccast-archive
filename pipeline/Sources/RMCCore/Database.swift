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

        migrator.registerMigration("createCollections") { db in
            try db.create(table: "collections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("slug", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("collectionDescription", .text).notNull()
                t.column("kind", .text).notNull()
            }
            try db.create(table: "collection_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("collectionId", .integer).notNull().indexed().references("collections", onDelete: .cascade)
                t.column("episodeId", .integer).notNull().indexed().references("episodes", onDelete: .cascade)
                t.column("segmentId", .integer).references("transcript_segments", onDelete: .setNull)
                t.column("timestampMs", .integer)
                t.column("blurb", .text).notNull()
            }
        }

        migrator.registerMigration("addEpisodeClassifiedAt") { db in
            try db.alter(table: "episodes") { t in
                t.add(column: "classifiedAt", .text)
            }
        }

        migrator.registerMigration("addCollectionSynthesizedParagraph") { db in
            try db.alter(table: "collections") { t in
                t.add(column: "synthesizedParagraph", .text)
            }
        }

        migrator.registerMigration("createTriviaFacts") { db in
            try db.create(table: "trivia_facts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("factText", .text).notNull()
                // Nullable, not cascading -- unlike a collection_item (which only exists
                // because of its episode), a trivia fact stands on its own even with no
                // episode attached (a cross-episode aggregate fact), so losing the episode
                // should null the link out rather than delete the fact.
                t.column("episodeId", .integer).indexed().references("episodes", onDelete: .setNull)
                t.column("segmentId", .integer).references("transcript_segments", onDelete: .setNull)
                t.column("timestampMs", .integer)
                t.column("createdAt", .text).notNull()
            }
        }

        return migrator
    }
}
